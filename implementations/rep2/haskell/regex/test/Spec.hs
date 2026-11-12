module Main (main) where

import Data.IORef
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (intercalate)
import Test.Hspec
import Test.QuickCheck

import Reference (refMatch)
import Text.Regex.Backtrack
import Text.Regex.Backtrack.Batch
import qualified Text.Regex.Backtrack.CharSet as CS
import Text.Regex.Backtrack.Parser (parseRegex)
import Text.Regex.Backtrack.Syntax

-- | Match result as the list of spans: whole match first, then groups.
spans :: String -> String -> Maybe [Maybe (Int, Int)]
spans pat subj = do
  let re = compileOrError pat
  m <- match re subj
  pure (Just (matchStart m, matchEnd m) : matchGroups m)

runBatchString :: String -> IO (Either BatchError String)
runBatchString inp = do
  ref <- newIORef mempty
  r <- runBatch (\b -> modifyIORef ref (<> b)) (BC.pack inp)
  out <- readIORef ref
  pure (BL.unpack (BB.toLazyByteString out) <$ r)

main :: IO ()
main = hspec $ do
  describe "matching semantics" $ do
    let j a b = Just (a, b)
    it "literals and search position" $ do
      spans "abc" "xxabcxx" `shouldBe` Just [j 2 5]
      spans "abc" "ab" `shouldBe` Nothing
    it "ordered choice beats longer match" $
      spans "a|ab" "ab" `shouldBe` Just [j 0 1]
    it "greedy with backtracking" $
      spans "(a|ab)(c|bcd)(d*)" "abcd" `shouldBe` Just [j 0 4, j 0 1, j 1 4, j 4 4]
    it "leftmost wins over longer" $
      spans "a*" "bbb" `shouldBe` Just [j 0 0]
    it "keeps earlier iteration's capture of an untouched group" $
      spans "(a|(b))+" "ba" `shouldBe` Just [j 0 2, j 1 2, j 0 1]
    it "empty iteration ends the loop" $
      spans "(a*)*b" "aab" `shouldBe` Just [j 0 3, j 2 2]
    it "min iterations run even when empty" $
      spans "(a*){3}" "" `shouldBe` Just [j 0 0, j 0 0]
    it "{0} never runs the atom" $
      spans "(a){0}b|(c)?(d)" "xb" `shouldBe` Just [j 1 2, Nothing, Nothing, Nothing]
    it "anchors" $ do
      spans "^a" "ba" `shouldBe` Nothing
      spans "a$" "aba" `shouldBe` Just [j 2 3]
      spans "a^b" "ab" `shouldBe` Nothing
      spans "x$|^(y)?z" "xz" `shouldBe` Nothing
    it "counted quantifiers" $ do
      spans "[^a-c]\\d{2,3}x?" "zz123xx" `shouldBe` Just [j 1 6]
      spans "a{2,}" "caaaa" `shouldBe` Just [j 1 5]
      spans "a{2,3}" "a" `shouldBe` Nothing
    it "classes and escapes" $ do
      spans "[a-c-]+" "xx-ab-" `shouldBe` Just [j 2 6]
      spans "\\w+\\s\\S" "ab cd" `shouldBe` Just [j 0 4]
      spans "\\(\\)\\ " "() " `shouldBe` Just [j 0 3]
      spans "[\\]\\-x]+" "a]-x" `shouldBe` Just [j 1 4]
    it "handles deep backtracking on long subjects" $ do
      let long = replicate 10000 'a'
      spans ".*b" long `shouldBe` Nothing
      spans "(a|b)*" long `shouldBe` Just [j 0 10000, j 9999 10000]
    it "exposes group count and text" $ do
      let re = compileOrError "(a)(b)?"
      m <- maybe (expectationFailure "no match" >> fail "no match") pure (match re "xa")
      groupCount re `shouldBe` 2
      groupText (BC.pack "xa") m 1 `shouldBe` Just (BC.pack "a")
      groupText (BC.pack "xa") m 2 `shouldBe` Nothing
      matchedText (BC.pack "xa") m `shouldBe` BC.pack "a"

  describe "parser" $ do
    it "numbers groups by opening parenthesis" $
      fmap patternGroups (parseRegex "((a)|(b))(c)") `shouldBe` Right 4
    it "builds the expected tree" $
      fmap patternNode (parseRegex "a|b*")
        `shouldBe` Right (Alt [Seq [Literal 'a'], Seq [Repeat 0 Nothing (Literal 'b')]])
    it "resolves classes to sets" $
      fmap patternNode (parseRegex "[^a-c]")
        `shouldBe` Right (Seq [Class (CS.complement (CS.range 'a' 'c'))])
    it "rejects invalid patterns" $ do
      let bad p = either (const True) (const False) (parseRegex p)
      mapM_ (\p -> (p, bad p) `shouldBe` (p, True))
        ["*a", "a**", "(a", "a)", "[a", "[]", "[b-a]", "a{2,1}", "a{", "\\q", "^*", "a{101}", "]", "a|*"]
    it "reports the offset of an error" $
      parseRegex "ab(*)" `shouldSatisfy` either ((== 3) . parseErrorOffset) (const False)

  describe "CharSet" $ do
    it "supports membership and complement" $ do
      CS.member 'b' (CS.range 'a' 'c') `shouldBe` True
      CS.member 'd' (CS.range 'a' 'c') `shouldBe` False
      CS.member 'd' (CS.complement (CS.range 'a' 'c')) `shouldBe` True
      CS.member '\1000' CS.full `shouldBe` False

  describe "batch format" $ do
    it "reproduces the specification examples" $ do
      runBatchString "3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"
        `shouldReturn` Right "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n"
      runBatchString "2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n"
        `shouldReturn` Right "match 0 2|1,2|0,1\nmatch 0 2|1,2|1,2\nmatch 1 6\nno\n"
    it "keeps whitespace and empty lines verbatim; M = 0 prints nothing" $
      runBatchString "3\n a \n2\n a \n\nx\n0\n \n1\n \n"
        `shouldReturn` Right "match 0 3\nno\nmatch 0 1\n"
    it "reports malformed input and bad patterns" $ do
      runBatchString "1\na\n2\nx\n" `shouldReturn` Left (MalformedInput "pattern 1: too few subjects")
      runBatchString "1\n(a\n0\n" >>= (`shouldSatisfy` either isBadPattern (const False))

  describe "properties" $ do
    it "agrees with the reference implementation of the specification" $
      withNumTests 3000 $ forAll genCase $ \(pat, subj) ->
        case parseRegex pat of
          Left e -> counterexample ("generated invalid pattern: " ++ show e) False
          Right p ->
            let s = BC.pack subj
            in refMatch p s === matchBytes (compileOrError pat) s
    it "reports well-formed spans" $
      withNumTests 1000 $ forAll genCase $ \(pat, subj) ->
        case match (compileOrError pat) subj of
          Nothing -> property True
          Just m ->
            let n = length subj
                ok (a, b) = 0 <= a && a <= b && b <= n
            in property (ok (matchStart m, matchEnd m) && all (maybe True ok) (matchGroups m)
                         && length (matchGroups m) == groupCount (compileOrError pat))
  where
    isBadPattern (BadPattern 1 _) = True
    isBadPattern _ = False

-- ---------------------------------------------------------------------------
-- Generators

genCase :: Gen (String, String)
genCase = (,) <$> sized (\n -> genRegex (min 4 (n `div` 8))) <*> genSubject

genSubject :: Gen String
genSubject = do
  n <- choose (0, 8)
  vectorOf n (elements "aabbc_1 ")

genRegex :: Int -> Gen String
genRegex d = intercalate "|" <$> do
  n <- frequency [(5, pure 1), (3, pure 2), (1, pure 3)]
  vectorOf n (genBranch d)

genBranch :: Int -> Gen String
genBranch d = do
  n <- frequency [(1, pure 0), (3, pure 1), (4, pure 2), (2, pure 3)]
  concat <$> vectorOf n (genPiece d)

genPiece :: Int -> Gen String
genPiece d = do
  (a, canQuantify) <- genAtom d
  if not canQuantify then pure a else do
    q <- frequency
      [ (4, pure ""), (2, pure "*"), (2, pure "+"), (2, pure "?")
      , (1, do n <- choose (0, 3 :: Int); pure ("{" ++ show n ++ "}"))
      , (1, do n <- choose (0, 2 :: Int); pure ("{" ++ show n ++ ",}"))
      , (1, do n <- choose (0, 2 :: Int); m <- choose (n, 3); pure ("{" ++ show n ++ "," ++ show m ++ "}"))
      ]
    pure (a ++ q)

genAtom :: Int -> Gen (String, Bool)
genAtom d = frequency $
  [ (6, flip (,) True . (: []) <$> elements "abc_1 ")
  , (2, pure (".", True))
  , (2, flip (,) True <$> elements ["[ab]", "[^a]", "[a-c1]", "\\d", "\\w", "\\W", "\\s", "[^\\d_]"])
  , (1, flip (,) True <$> elements ["\\.", "\\-", "\\ "])
  , (1, flip (,) False <$> elements ["^", "$"])
  ] ++
  [ (4, do r <- genRegex (d - 1); pure ("(" ++ r ++ ")", True)) | d > 0 ]

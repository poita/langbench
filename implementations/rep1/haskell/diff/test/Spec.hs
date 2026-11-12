module Main (main) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8   as BC
import qualified Data.ByteString.Lazy    as BL
import           Data.Array.Unboxed      (listArray)
import           Test.Hspec
import           Test.QuickCheck

import           Diff
import           Diff.Protocol           (process)
import           Diff.Script             (parseEdit, renderScript)

-- | Length of a longest common subsequence, by the textbook O(NM) table.
lcsLength :: Eq a => [a] -> [a] -> Int
lcsLength xs ys = last (foldl row (replicate (length ys + 1) 0) xs)
  where
    row prev x = scanl step 0 (zip3 ys prev (tail prev))
      where
        -- left value is threaded through scanl; diag = prev[j], up = prev[j+1]
        step left (y, diag, up)
          | x == y    = diag + 1
          | otherwise = max left up

minimalCost :: Eq a => [a] -> [a] -> Int
minimalCost xs ys = length xs + length ys - 2 * lcsLength xs ys

-- | Check script validity and minimality; returns a failure description.
checkScript :: (Eq a, Show a) => [a] -> [a] -> [Edit a] -> Property
checkScript xs ys es =
  counterexample ("script: " ++ show es) $
    old === xs .&&. new === ys .&&. scriptCost es === minimalCost xs ys
  where
    old = [x | e <- es, x <- case e of { Keep x -> [x]; Delete x -> [x]; _ -> [] }]
    new = [x | e <- es, x <- case e of { Keep x -> [x]; Insert x -> [x]; _ -> [] }]

-- | Sequences over a small alphabet, so duplicates are plentiful.
smallSeq :: Int -> Gen [Int]
smallSeq alphabet = do
  n <- choose (0, 25)
  vectorOf n (choose (0, alphabet - 1))

pairGen :: Gen ([Int], [Int])
pairGen = do
  k <- elements [1, 2, 3, 5, 26]
  (,) <$> smallSeq k <*> smallSeq k

-- | A sequence and a perturbed copy of it.
editedPair :: Gen ([Int], [Int])
editedPair = do
  xs <- do { n <- choose (0, 60); vectorOf n (choose (0, 8)) }
  ys <- perturb xs
  pure (xs, ys)
  where
    perturb [] = pure []
    perturb (z : zs) = do
      r <- choose (0 :: Int, 9)
      rest <- perturb zs
      pure $ case r of
        0 -> rest
        1 -> z : 100 : rest
        2 -> 101 : z : rest
        _ -> z : rest

runCli :: String -> String
runCli s = case process (BC.pack s) of
  Left err -> "ERROR " ++ err
  Right b  -> BC.unpack (BL.toStrict (BB.toLazyByteString b))

main :: IO ()
main = hspec $ do
  describe "diff" $ do
    it "handles empty inputs" $ do
      diff ([] :: [Int]) [] `shouldBe` []
      diff [1, 2 :: Int] [] `shouldBe` [Delete 1, Delete 2]
      diff [] [1, 2 :: Int] `shouldBe` [Insert 1, Insert 2]
    it "keeps identical sequences entirely" $
      diff "hello" "hello" `shouldBe` map Keep "hello"
    it "yields a valid minimal script for Myers' paper example" $
      checkScript "abcabba" "cbabac" (diff "abcabba" "cbabac")
    it "is minimal on Myers' paper example" $
      scriptCost (diff "abcabba" "cbabac") `shouldBe` 5
    it "is minimal on fully disjoint inputs" $
      scriptCost (diff [1 .. 50 :: Int] [51 .. 120]) `shouldBe` 120
    it "is minimal on a repeated-line example" $
      scriptCost (diff "xxxyxx" "xyxxxy") `shouldBe` 4
    it "is valid and minimal on random small-alphabet pairs" $
      withMaxSuccess 3000 $ forAll pairGen $ \(xs, ys) -> checkScript xs ys (diff xs ys)
    it "is valid and minimal on random edited copies" $
      withMaxSuccess 1000 $ forAll editedPair $ \(xs, ys) -> checkScript xs ys (diff xs ys)
    it "is symmetric in cost" $
      forAll pairGen $ \(xs, ys) -> scriptCost (diff xs ys) === scriptCost (diff ys xs)
    it "diffBy compares through the key" $
      scriptCost (diffBy fst [(1 :: Int, 'a'), (2, 'b')] [(1, 'z'), (3, 'c')]) `shouldBe` 2
    it "diffIds agrees with diff on interned input" $ do
      let a = listArray (0, 6) [0, 1, 2, 0, 1, 1, 0]
          b = listArray (0, 5) [2, 1, 0, 1, 0, 2]
      scriptCost (diffIds a b) `shouldBe` 5

  describe "patch" $ do
    it "reproduces the target" $
      forAll pairGen $ \(xs, ys) -> patch xs (diff xs ys) === Right ys
    it "applies a non-minimal script" $
      patch "abc" [Delete 'a', Insert 'a', Keep 'b', Insert 'x', Delete 'c']
        `shouldBe` Right "abx"
    it "rejects a script that does not match the source" $ do
      patch "abc" [Keep 'a', Keep 'x', Keep 'c'] `shouldBe` Left ElementMismatch
      patch "abc" [Keep 'a'] `shouldBe` Left ElementsLeftOver
      patch "a" [Keep 'a', Keep 'b'] `shouldBe` Left ScriptEndsEarly

  describe "script format" $ do
    it "parses tags" $ do
      parseEdit (BC.pack " x") `shouldBe` Right (Keep (BC.pack "x"))
      parseEdit (BC.pack "-") `shouldBe` Right (Delete (BC.pack ""))
      parseEdit (BC.pack "+-x") `shouldBe` Right (Insert (BC.pack "-x"))
      parseEdit (BC.pack "?x") `shouldSatisfy` either (const True) (const False)
    it "renders a counted script" $
      BL.toStrict (BB.toLazyByteString (renderScript [Keep (BC.pack "a"), Insert (BC.pack "")]))
        `shouldBe` BC.pack "2\n a\n+\n"

  describe "protocol" $ do
    it "diffs (empty files)" $ runCli "diff\n0\n0\n" `shouldBe` "0\n"
    it "diffs identical files" $ runCli "diff\n2\na\nb\n2\na\nb\n" `shouldBe` "2\n a\n b\n"
    it "patches (spec example 3)" $
      runCli "patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n"
        `shouldBe` "6\na\nB\nc\nc2\ne\nf\n"
    it "patches to an empty file" $ runCli "patch\n1\nx\n1\n-x\n" `shouldBe` "0\n"
    it "treats lines that look like counts or tags as content" $ do
      runCli "diff\n2\n5\n-\n2\n5\n+\n" `shouldBe` "3\n 5\n++\n--\n"
      runCli "patch\n1\n \n2\n  \n+ \n" `shouldBe` "2\n \n \n"
    it "preserves whitespace" $
      runCli "patch\n1\n a \n2\n  a \n+ \n" `shouldBe` "2\n a \n \n"
    it "reports malformed input" $
      runCli "bogus\n" `shouldSatisfy` ((== "ERROR") . take 5)

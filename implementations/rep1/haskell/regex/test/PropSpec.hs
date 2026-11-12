{-# LANGUAGE ScopedTypeVariables #-}
module PropSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as M
import Test.Hspec
import Test.QuickCheck

import Regex
import Regex.Parser (parsePattern)
import Reference

-- | Random patterns over a tiny alphabet, as source text.
genPattern :: Gen String
genPattern = genRegex 2

genRegex :: Int -> Gen String
genRegex d = do
  n <- chooseInt (1, 2)
  branches <- vectorOf n (genBranch d)
  pure (foldr1 (\a b -> a ++ "|" ++ b) branches)

genBranch :: Int -> Gen String
genBranch d = do
  n <- chooseInt (0, 3)
  concat <$> vectorOf n (genPiece d)

genPiece :: Int -> Gen String
genPiece d = frequency
  [ (10, (++) <$> genAtom d <*> genQuant)
  , (1, elements ["^", "$"])
  ]

genAtom :: Int -> Gen String
genAtom d = frequency $
  [ (6, elements ["a", "b", "c"])
  , (2, pure ".")
  , (2, elements ["[ab]", "[^a]", "[a-c]", "\\d", "\\w", "\\W", "[\\d-]"])
  ] ++
  [ (3, (\r -> "(" ++ r ++ ")") <$> genRegex (d - 1)) | d > 0 ]

genQuant :: Gen String
genQuant = frequency
  [ (6, pure ""), (3, pure "*"), (2, pure "+"), (2, pure "?")
  , (2, elements ["{0}", "{2}", "{1,}", "{0,2}", "{1,3}", "{2,}"])
  ]

genSubject :: Gen String
genSubject = do
  n <- chooseInt (0, 8)
  vectorOf n (elements "aabbc1_-")

spec :: Spec
spec = do
  it "agrees with the naive transcription of the definition" $
    withNumTests 3000 $
      forAll genPattern $ \pat -> forAll genSubject $ \subj ->
        case (compile pat, parsePattern pat) of
          (Right re, Right tree) ->
            let subject = BC.pack subj
                expected = case refSearch tree subject of
                  Nothing -> Nothing
                  Just (s, e, caps) ->
                    Just (Match s e [M.lookup g caps | g <- [1 .. groupCount re]])
            in counterexample (show (pat, subj)) (search re subject === expected)
          (l, _) -> counterexample ("generated an invalid pattern: " ++ show (pat, either show (const "") l)) False
  it "finds an escaped literal string wherever it occurs" $
    property $ \(NonEmpty xs) (pre :: String) (post :: String) ->
      let clean = filter (\c -> c >= ' ' && c <= '~') 
          lit = clean xs
          p = concatMap (\c -> if c `elem` ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] then [c] else ['\\', c]) lit
          subject = clean pre ++ lit ++ clean post
      in not (null lit) ==>
           case compile p of
             Right re -> fmap matchEnd (search re (BC.pack subject)) /= Nothing
             Left _   -> False

{-# LANGUAGE NoOverloadedStrings #-}
module GlobSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate, isPrefixOf)
import Test.Hspec
import Test.QuickCheck

import Kiln.Glob

matches :: String -> String -> Bool
matches pat cand = case compilePattern (BC.pack pat) of
  Nothing -> error ("malformed pattern in test: " ++ pat)
  Just p -> matchPattern p (BC.pack cand)

-- A deliberately naive reference matcher over a restricted pattern alphabet.
splitSlash :: String -> [String]
splitSlash s = case break (== '/') s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitSlash rest

refComponent :: String -> String -> Bool
refComponent [] [] = True
refComponent ('*' : ps) cs = any (refComponent ps) [drop k cs | k <- [0 .. length cs]]
refComponent ('?' : ps) (_ : cs) = refComponent ps cs
refComponent ('[' : 'a' : 'b' : ']' : ps) (c : cs) = c `elem` "ab" && refComponent ps cs
refComponent (p : ps) (c : cs) = p == c && refComponent ps cs
refComponent _ _ = False

refMatch :: [String] -> [String] -> Bool
refMatch [] [] = True
refMatch ("**" : ps) cs = refMatch ps cs || (not (null cs) && refMatch ("**" : ps) (drop 1 cs))
refMatch (p : ps) (c : cs) = refComponent p c && refMatch ps cs
refMatch _ _ = False

genPattern :: Gen String
genPattern = intercalate "/" <$> listOf1 (elements ["a", "b", "*", "?", "a*", "*b", "**", "[ab]", "a?b", "*a*"])

genCandidate :: Gen String
genCandidate = intercalate "/" <$> listOf1 (elements ["a", "b", "ab", "ba", "aab", "", "abab"])

spec :: Spec
spec = do
  describe "specification examples" $ do
    let yes pat cs = mapM_ (\c -> it (pat ++ " matches " ++ c) (matches pat c `shouldBe` True)) cs
        no pat cs = mapM_ (\c -> it (pat ++ " rejects " ++ c) (matches pat c `shouldBe` False)) cs
    yes "src/*.txt" ["src/a.txt", "src/.txt"]
    no "src/*.txt" ["src/sub/a.txt", "a.txt"]
    yes "src/**" ["src/a.txt", "src/x/y/z.txt", "src"]
    no "src/**" ["other/a.txt", "srcx"]
    yes "**/*.txt" ["a.txt", "src/a.txt", "a/b/c.txt"]
    no "**/*.txt" ["a.text"]
    yes "src/**/t_*.txt" ["src/t_1.txt", "src/a/b/t_2.txt"]
    no "src/**/t_*.txt" ["src/t.txt"]
    yes "src/?.txt" ["src/a.txt"]
    no "src/?.txt" ["src/ab.txt"]
    yes "src/[ab]*.txt" ["src/a1.txt", "src/b.txt"]
    no "src/[ab]*.txt" ["src/c.txt"]
    yes "src/[!ab]*.txt" ["src/c.txt"]
    no "src/[!ab]*.txt" ["src/a.txt"]
    yes "src/[0-9].txt" ["src/7.txt"]
    no "src/[0-9].txt" ["src/x.txt"]
    yes "a**b" ["axyzb", "ab"]
    no "a**b" ["a/b"]
    yes "[-a]" ["-", "a"]
    yes "[a-]" ["a", "-"]
    yes "[*?]" ["*", "?"]

  describe "empty candidate components" $ do
    it "* and ** match the empty string, ? does not" $ do
      matches "*" "" `shouldBe` True
      matches "**" "" `shouldBe` True
      matches "?" "" `shouldBe` False
    it "keeps empty components" $ do
      matches "*" "a//b" `shouldBe` False
      matches "*/*" "x/" `shouldBe` True
      matches "*/*" "/x" `shouldBe` True

  describe "malformed patterns" $ do
    let bad p = it (show p ++ " is malformed") (compilePattern (BC.pack p) `shouldSatisfy` null')
        null' = maybe True (const False)
    mapM_ bad ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[a", "[z-a]", "a/[b"]
    it "accepts ] as an ordinary byte outside classes" $ matches "a]" "a]" `shouldBe` True

  describe "literalPrefix" $ do
    it "stops at the first wildcard" $ BC.unpack (literalPrefix (BC.pack "src/a*")) `shouldBe` "src/a"
    it "drops the slash before a ** component" $ BC.unpack (literalPrefix (BC.pack "src/**")) `shouldBe` "src"
    it "keeps the slash before other wildcards" $ BC.unpack (literalPrefix (BC.pack "src/*.txt")) `shouldBe` "src/"
    it "is empty for a leading wildcard" $ BC.unpack (literalPrefix (BC.pack "**/x")) `shouldBe` ""

  describe "properties" $ do
    it "agrees with a naive reference matcher" $
      property $ forAll genPattern $ \p -> forAll genCandidate $ \c ->
        matches p c === refMatch (splitSlash p) (splitSlash c)
    it "every match starts with the literal prefix" $
      property $ forAll genPattern $ \p -> forAll genCandidate $ \c ->
        not (matches p c) || BC.unpack (literalPrefix (BC.pack p)) `isPrefixOf` c

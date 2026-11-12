module GlobSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec
import Test.QuickCheck

import Kiln.Glob

matches :: String -> String -> Maybe Bool
matches pat cand = (\p -> matchPattern p (BC.pack cand)) <$> compilePattern (BC.pack pat)

spec :: Spec
spec = do
  describe "matching (table from the specification)" $ do
    let yes p c = it (p ++ " matches " ++ show c) $ matches p c `shouldBe` Just True
        no p c = it (p ++ " does not match " ++ show c) $ matches p c `shouldBe` Just False
    yes "src/*.txt" "src/a.txt"
    yes "src/*.txt" "src/.txt"
    no "src/*.txt" "src/sub/a.txt"
    no "src/*.txt" "a.txt"
    yes "src/**" "src"
    yes "src/**" "src/x/y/z.txt"
    no "src/**" "srcx"
    yes "**/*.txt" "a.txt"
    yes "**/*.txt" "a/b/c.txt"
    no "**/*.txt" "a.text"
    yes "src/**/t_*.txt" "src/a/b/t_2.txt"
    no "src/**/t_*.txt" "src/t.txt"
    yes "src/?.txt" "src/a.txt"
    no "src/?.txt" "src/ab.txt"
    yes "src/[ab]*.txt" "src/a1.txt"
    no "src/[!ab]*.txt" "src/a.txt"
    yes "src/[0-9].txt" "src/7.txt"
    yes "a**b" "axyzb"
    no "a**b" "a/b"
    yes "[-a]" "-"
    yes "[a-]" "-"
    yes "[*?]" "?"
  describe "empty candidate components" $ do
    it "* and ** match an empty component, ? does not" $ do
      matches "*" "" `shouldBe` Just True
      matches "**" "" `shouldBe` Just True
      matches "?" "" `shouldBe` Just False
    it "* does not match a//b" $ matches "*" "a//b" `shouldBe` Just False
  describe "malformed patterns" $
    mapM_
      (\p -> it (show p) $ matches p "x" `shouldBe` Nothing)
      ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[b-a]", "[abc", "a[/]b"]
  describe "literalPrefix" $ do
    it "stops at the first wildcard" $
      fmap literalPrefix (compilePattern "src/a*.txt") `shouldBe` Just "src/a"
    it "drops the slash before ** (src/** matches src)" $
      fmap literalPrefix (compilePattern "src/**") `shouldBe` Just "src"
  describe "properties" $ do
    it "a wildcard-free pattern matches only itself" $
      property $ \(NonEmpty xs) ys ->
        let p = filter (`elem` ['a' .. 'e']) xs
            q = filter (`elem` ['a' .. 'e']) ys
         in not (null p) ==> (matches p q == Just (p == q))
    it "** matches any candidate" $
      property $ \s -> matches "**" (filter (/= '\n') s) == Just True

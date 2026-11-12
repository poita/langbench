{-# LANGUAGE OverloadedStrings #-}
module CorpusSpec (spec) where

import qualified Data.Text as T
import Test.Hspec

import Fulltext.Corpus

q :: Int -> Int -> String -> QueryJob
q n k t = QueryJob n k (T.pack t)

spec :: Spec
spec = describe "parseQueryFile" $ do
  it "numbers queries and skips blanks and comments" $
    parseQueryFile "# note\n\n  cat  \n\t\ndog AND bird\n"
      `shouldBe` [q 1 10 "cat", q 2 10 "dog AND bird"]
  it "applies %k to the queries after it" $
    parseQueryFile "a1\n%k 3\nb1\n%k\t25 \nc1"
      `shouldBe` [q 1 10 "a1", q 2 3 "b1", q 3 25 "c1"]
  it "accepts a missing final newline and an empty file" $ do
    parseQueryFile "cat" `shouldBe` [q 1 10 "cat"]
    parseQueryFile "" `shouldBe` []
  it "strips no-break spaces and other whitespace" $
    parseQueryFile "\xA0\&cat\x0B\x0C\n" `shouldBe` [q 1 10 "cat"]
  it "does not treat malformed %k lines as directives" $
    parseQueryFile "%k\n%k x\n%kk 3\n%k 3x" `shouldBe`
      [q 1 10 "%k", q 2 10 "%k x", q 3 10 "%kk 3", q 4 10 "%k 3x"]

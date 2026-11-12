{-# LANGUAGE OverloadedStrings #-}
module OrderedMap.CommandSpec (spec) where

import Data.Either (isLeft)
import OrderedMap.Command
import Test.Hspec

spec :: Spec
spec = do
  it "parses every command form" $ do
    parseCommand "insert 5 five" `shouldBe` Right (Insert 5 "five")
    parseCommand "delete -3" `shouldBe` Right (Delete (-3))
    parseCommand "get 0" `shouldBe` Right (Get 0)
    parseCommand "size" `shouldBe` Right Size
    parseCommand "min" `shouldBe` Right Min
    parseCommand "max" `shouldBe` Right Max
    parseCommand "floor 1" `shouldBe` Right (Floor 1)
    parseCommand "ceil 1" `shouldBe` Right (Ceil 1)
    parseCommand "succ 1" `shouldBe` Right (Succ 1)
    parseCommand "pred 1" `shouldBe` Right (Pred 1)
    parseCommand "rank 1" `shouldBe` Right (Rank 1)
    parseCommand "select 7" `shouldBe` Right (Select 7)
    parseCommand "range 1 9" `shouldBe` Right (Range 1 9)
  it "accepts the 64-bit extremes" $ do
    parseCommand "get -9223372036854775808" `shouldBe` Right (Get minBound)
    parseCommand "get 9223372036854775807" `shouldBe` Right (Get maxBound)
  it "treats values as opaque, including keyword-like and punctuation" $ do
    parseCommand "insert 1 missing" `shouldBe` Right (Insert 1 "missing")
    parseCommand "insert 1 \"'`\\<>|{}#" `shouldBe` Right (Insert 1 "\"'`\\<>|{}#")
  it "rejects malformed lines" $ do
    parseCommand "" `shouldSatisfy` isLeft
    parseCommand "bogus 1" `shouldSatisfy` isLeft
    parseCommand "insert 1" `shouldSatisfy` isLeft
    parseCommand "get abc" `shouldSatisfy` isLeft
    parseCommand "get 1 2" `shouldSatisfy` isLeft
    parseCommand "get 9223372036854775808" `shouldSatisfy` isLeft

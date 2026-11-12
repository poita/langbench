{-# LANGUAGE OverloadedStrings #-}
module Depresolve.RangeSpec (spec) where

import qualified Data.String
import Test.Hspec
import Test.QuickCheck

import Depresolve
import Depresolve.Gen (genRange, genVersion)
import Depresolve.Range (inInterval, rangeInterval)

accepts :: String -> String -> Bool
accepts r v = case (parseRange (fromS r), parseVersion (fromS v)) of
  (Right rg, Right ver) -> satisfies rg ver
  _ -> error "bad test input"
  where fromS = Data.String.fromString

spec :: Spec
spec = describe "Range" $ do
  describe "semantics" $ do
    it "* accepts everything" $ accepts "*" "9.9.9" `shouldBe` True
    it "exact matches only itself" $ do
      accepts "1.2.3" "1.2.3" `shouldBe` True
      accepts "1.2.3" "1.2.4" `shouldBe` False
    it "^X.Y.Z fixes the major" $ do
      accepts "^1.2.3" "1.9.0" `shouldBe` True
      accepts "^1.2.3" "1.2.2" `shouldBe` False
      accepts "^1.2.3" "2.0.0" `shouldBe` False
    it "^0.Y.Z fixes the minor" $ do
      accepts "^0.2.3" "0.2.9" `shouldBe` True
      accepts "^0.2.3" "0.3.0" `shouldBe` False
    it "^0.0.Z accepts only itself" $ do
      accepts "^0.0.3" "0.0.3" `shouldBe` True
      accepts "^0.0.3" "0.0.4" `shouldBe` False
    it "~ fixes major and minor, also for 0.x" $ do
      accepts "~0.0.3" "0.0.9" `shouldBe` True
      accepts "~0.0.3" "0.1.0" `shouldBe` False
      accepts "~1.2.0" "1.2.5" `shouldBe` True
      accepts "~1.2.0" "1.3.0" `shouldBe` False
    it "comparators must all hold" $ do
      accepts ">=1.0.0 <2.0.0" "1.5.0" `shouldBe` True
      accepts ">=1.0.0 <2.0.0" "2.0.0" `shouldBe` False
      accepts ">1.0.0" "1.0.0" `shouldBe` False
      accepts "<=1.0.0" "1.0.0" `shouldBe` True
      accepts ">=2.0.0 <1.0.0" "1.5.0" `shouldBe` False
  describe "parsing" $ do
    it "parses each form" $ do
      parseRange "*" `shouldBe` Right Any
      parseRange "^1.2.3" `shouldBe` Right (Caret (Version 1 2 3))
      parseRange "~1.2.3" `shouldBe` Right (Tilde (Version 1 2 3))
      parseRange ">=1.0.0 <2.0.0" `shouldBe`
        Right (Comparators [Comparator Ge (Version 1 0 0), Comparator Lt (Version 2 0 0)])
    it "rejects garbage" $
      parseRange "^" `shouldSatisfy` either (const True) (const False)
  describe "intervals" $
    it "agree with satisfies" $
      property $ forAll genRange $ \r -> forAll genVersion $ \v ->
        satisfies r v === inInterval (rangeInterval r) v

{-# LANGUAGE OverloadedStrings #-}
module Spreadsheet.FormatSpec (spec) where

import Data.Text (unpack)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Spreadsheet

fmt :: Double -> String
fmt = unpack . formatNumber

spec :: Spec
spec = do
  it "prints zero and integers plainly" $ do
    fmt 0 `shouldBe` "0"
    fmt (-0.0) `shouldBe` "0"
    fmt 42 `shouldBe` "42"
    fmt (-7) `shouldBe` "-7"
    fmt 123456789012345 `shouldBe` "123456789012345"
    fmt 1e14 `shouldBe` "100000000000000"
  it "switches to scientific notation at 1e15 for integers" $ do
    fmt 1e15 `shouldBe` "1e+15"
    fmt (-1.5e15) `shouldBe` "-1.5e+15"
    fmt 1.23456789e15 `shouldBe` "1.23456789e+15"
    fmt 1e20 `shouldBe` "1e+20"
  it "uses fixed notation for ordinary fractions" $ do
    fmt 0.5 `shouldBe` "0.5"
    fmt (-2.5) `shouldBe` "-2.5"
    fmt 1234567.891 `shouldBe` "1234567.891"
    fmt 0.0001234 `shouldBe` "0.0001234"
    fmt 0.1 `shouldBe` "0.1"
  it "rounds to ten significant digits" $ do
    fmt (1 / 3) `shouldBe` "0.3333333333"
    fmt (2 / 3) `shouldBe` "0.6666666667"
    fmt 1234567890.4 `shouldBe` "1234567890"
    fmt 2500000000.75 `shouldBe` "2500000001"
    fmt 1200000000.4 `shouldBe` "1200000000"
  it "breaks exact ties to even" $ do
    fmt 1234567890.5 `shouldBe` "1234567890"
    fmt 1234567891.5 `shouldBe` "1234567892"
  it "uses the exponent after rounding" $ do
    fmt 9999999999.7 `shouldBe` "1e+10"
    fmt 0.99999999999 `shouldBe` "1"
  it "uses scientific notation for small magnitudes" $ do
    fmt 0.00001 `shouldBe` "1e-05"
    fmt 2.5e-10 `shouldBe` "2.5e-10"
    fmt 1e-300 `shouldBe` "1e-300"
    fmt 0.00012345678912 `shouldBe` "0.0001234567891"
  it "renders values" $ do
    renderValue (VText ("hi")) `shouldBe` "hi"
    renderValue (VError ErrCycle) `shouldBe` "#CYCLE!"
    renderValue (VNumber 3) `shouldBe` "3"
  prop "output re-reads to within 10 significant digits" $
    forAll (suchThat (arbitrary :: Gen Double) (\d -> not (isNaN d || isInfinite d))) $ \d ->
      let back = read (fmt d) :: Double
       in d == 0 || abs (back - d) <= abs d * 1e-9
  prop "integers below 1e15 print without point or exponent" $
    forAll (choose (-999999999999999, 999999999999999 :: Int)) $ \n ->
      fmt (fromIntegral n) === show n

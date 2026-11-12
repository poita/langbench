{-# LANGUAGE OverloadedStrings #-}
module Spreadsheet.TypesSpec (spec) where

import Data.Maybe (fromJust)
import Test.Hspec

import Spreadsheet

ref :: Int -> Int -> CellRef
ref c r = fromJust (mkCellRef c r)

spec :: Spec
spec = do
  it "validates column and row bounds" $ do
    mkCellRef 0 1 `shouldBe` Nothing
    mkCellRef 1 0 `shouldBe` Nothing
    mkCellRef 703 1 `shouldBe` Nothing
    mkCellRef 1 10000 `shouldBe` Nothing
    mkCellRef 702 9999 `shouldSatisfy` (/= Nothing)
  it "renders and parses cell names" $ do
    showCellRef (ref 1 1) `shouldBe` "A1"
    showCellRef (ref 26 5) `shouldBe` "Z5"
    showCellRef (ref 27 5) `shouldBe` "AA5"
    showCellRef (ref 52 5) `shouldBe` "AZ5"
    showCellRef (ref 702 9999) `shouldBe` "ZZ9999"
    parseCellRef "AB123" `shouldBe` Just (ref 28 123)
    mapM_ (\t -> parseCellRef t `shouldBe` Nothing) ["AAA1", "A0", "A10000", "A01", "a1", "A", "1"]
  it "orders references row-major" $ do
    ref 2 1 `shouldSatisfy` (< ref 1 2)
    ref 1 1 `shouldSatisfy` (< ref 2 1)
  it "round-trips keys" $
    mapM_ (\r -> keyRef (refKey r) `shouldBe` r) [ref 1 1, ref 702 9999, ref 27 300]
  it "lists range cells row-major whatever the corner order" $
    map keyRef (rangeKeys (ref 2 2) (ref 1 1)) `shouldBe` [ref 1 1, ref 2 1, ref 1 2, ref 2 2]

{-# LANGUAGE OverloadedStrings #-}
module Spreadsheet.SheetSpec (spec) where

import Data.Maybe (fromJust)
import Data.Text (Text)
import Test.Hspec

import Spreadsheet
import qualified Spreadsheet.Sheet as Sheet

cell :: Text -> CellRef
cell = fromJust . parseCellRef

-- | Apply @set@ commands (name, content).
build :: [(Text, Text)] -> Sheet
build = foldl (\s (c, t) -> either (error . show) id (setCell (cell c) t s)) Sheet.empty

val :: Text -> Sheet -> Maybe Text
val c s = renderValue <$> lookupValue (cell c) s

spec :: Spec
spec = do
  it "starts empty" $ do
    size Sheet.empty `shouldBe` 0
    toList Sheet.empty `shouldBe` []
  it "stores literals" $ do
    let s = build [("A1", "5"), ("A2", "\"hi\"")]
    val "A1" s `shouldBe` Just "5"
    val "A2" s `shouldBe` Just "hi"
    lookupContent (cell "A1") s `shouldBe` Just (CNumber 5)
    val "B1" s `shouldBe` Nothing
  it "recalculates dependants after an edit, through chains" $ do
    let s = build [("A1", "1"), ("B1", "=A1+1"), ("C1", "=B1*2"), ("D1", "=SUM(A1:C1)")]
    val "D1" s `shouldBe` Just "7"
    let Right s' = setCell (cell "A1") "10" s
    val "C1" s' `shouldBe` Just "22"
    val "D1" s' `shouldBe` Just "43"
  it "treats a formula that references a later-defined cell correctly" $ do
    let s = build [("A1", "=B1+1"), ("B1", "4")]
    val "A1" s `shouldBe` Just "5"
  it "detects self-references and cycles, and recovers" $ do
    let s = build [("A1", "=A1+1"), ("B1", "=C1"), ("C1", "=B1"), ("D1", "=B1+1"), ("E1", "=IF(1,5,B1)")]
    val "A1" s `shouldBe` Just "#CYCLE!"
    val "B1" s `shouldBe` Just "#CYCLE!"
    val "C1" s `shouldBe` Just "#CYCLE!"
    val "D1" s `shouldBe` Just "#CYCLE!"
    val "E1" s `shouldBe` Just "5" -- not itself cyclic, and IF does not select B1
    let s' = build [("A1", "=A1+1"), ("B1", "=C1"), ("C1", "=B1"), ("C1", "7")]
    val "B1" s' `shouldBe` Just "7"
    val "C1" s' `shouldBe` Just "7"
  it "reports a cell whose range includes itself as cyclic" $
    val "A1" (build [("A1", "=SUM(A1:A3)")]) `shouldBe` Just "#CYCLE!"
  it "lets IF mask a cyclic cell it does not select" $ do
    let s = build [("A1", "=A1"), ("B1", "=IF(0,A1,3)")]
    val "B1" s `shouldBe` Just "3"
  it "treats a cleared cell as empty for its readers" $ do
    let s = build [("A1", "5"), ("B1", "=A1+1"), ("C1", "=A1&\"x\"")]
        s' = clearCell (cell "A1") s
    val "A1" s' `shouldBe` Nothing
    val "B1" s' `shouldBe` Just "1"
    val "C1" s' `shouldBe` Just "x"
    size s' `shouldBe` 2
  it "ignores clearing an empty cell" $
    size (clearCell (cell "A1") Sheet.empty) `shouldBe` 0
  it "drops old dependencies when a formula is replaced" $ do
    let s = build [("A1", "1"), ("B1", "2"), ("C1", "=A1"), ("C1", "=B1")]
        Right s' = setCell (cell "A1") "100" s
    val "C1" s' `shouldBe` Just "2"
  it "gives a formula with an invalid reference #REF!" $
    val "A1" (build [("A1", "=AAA1+1")]) `shouldBe` Just "#REF!"
  it "gives an empty-valued formula the number 0" $
    val "A1" (build [("A1", "=B1")]) `shouldBe` Just "0"
  it "lists cells in row-major order" $
    map (showCellRef . fst) (toList (build [("B2", "1"), ("A2", "1"), ("C1", "1"), ("AA1", "1")]))
      `shouldBe` ["C1", "AA1", "A2", "B2"]
  it "reports syntax errors from setCell" $
    case setCell (cell "A1") "=1+" Sheet.empty of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected a parse error"

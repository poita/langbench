{-# LANGUAGE OverloadedStrings #-}
module Spreadsheet.ParserSpec (spec) where

import Data.Either (isLeft)
import Data.Maybe (fromJust)
import Test.Hspec

import Spreadsheet

a1, b2 :: CellRef
a1 = fromJust (parseCellRef "A1")
b2 = fromJust (parseCellRef "B2")

spec :: Spec
spec = do
  describe "parseNumber" $ do
    it "accepts the literal grammar" $ do
      parseNumber "5" `shouldBe` Just 5
      parseNumber "-3" `shouldBe` Just (-3)
      parseNumber "4.50" `shouldBe` Just 4.5
      parseNumber "007" `shouldBe` Just 7
    it "rounds correctly" $ do
      parseNumber "0.1" `shouldBe` Just 0.1
      parseNumber "9007199254740993" `shouldBe` Just 9007199254740992
    it "treats -0 as zero" $
      fmap isNegativeZero (parseNumber "-0") `shouldBe` Just False
    it "rejects malformed numbers" $
      mapM_ (\t -> parseNumber t `shouldBe` Nothing) ["", "-", "1.", ".5", "1.2.3", "abc", "+1", "1e5"]
  describe "parseContent" $ do
    it "recognises the three forms" $ do
      parseContent "12" `shouldBe` Right (CNumber 12)
      parseContent "\"a b\"" `shouldBe` Right (CText "a b")
      parseContent "\"\"" `shouldBe` Right (CText "")
      parseContent "=1" `shouldBe` Right (CFormula (ENumber 1))
    it "rejects a malformed string" $ do
      parseContent "\"abc" `shouldSatisfy` isLeft
      parseContent "\"" `shouldSatisfy` isLeft
  describe "parseFormula" $ do
    it "respects precedence and associativity" $ do
      parseFormula "1+2*3"
        `shouldBe` Right (EBinary Add (ENumber 1) (EBinary Mul (ENumber 2) (ENumber 3)))
      parseFormula "1-2-3"
        `shouldBe` Right (EBinary Sub (EBinary Sub (ENumber 1) (ENumber 2)) (ENumber 3))
      parseFormula "1+2&3"
        `shouldBe` Right (EBinary Concat (EBinary Add (ENumber 1) (ENumber 2)) (ENumber 3))
      parseFormula "1<2+3"
        `shouldBe` Right (EBinary Lt (ENumber 1) (EBinary Add (ENumber 2) (ENumber 3)))
      parseFormula "-2*3" `shouldBe` Right (EBinary Mul (ENeg (ENumber 2)) (ENumber 3))
      parseFormula "--5" `shouldBe` Right (ENeg (ENeg (ENumber 5)))
    it "ignores spaces between tokens but not inside strings" $
      parseFormula " A1 + \" x \" " `shouldBe` Right (EBinary Add (ERef a1) (EString " x "))
    it "parses all comparison operators" $
      mapM_
        (\(s, op) -> parseFormula ("1" <> s <> "2") `shouldBe` Right (EBinary op (ENumber 1) (ENumber 2)))
        [("=", Eq), ("<>", Ne), ("<", Lt), (">", Gt), ("<=", Le), (">=", Ge)]
    it "parses calls and ranges" $ do
      parseFormula "SUM(B2:A1, 3)"
        `shouldBe` Right (ECall Sum [ArgRange b2 a1, ArgExpr (ENumber 3)])
      parseFormula "IF(A1,1,2)" `shouldBe` Right (EIf (ERef a1) (ENumber 1) (ENumber 2))
      parseFormula "COUNT((A1))" `shouldBe` Right (ECall Count [ArgExpr (ERef a1)])
    it "collapses formulas with an invalid reference to EInvalidRef" $
      mapM_
        (\s -> parseFormula s `shouldBe` Right EInvalidRef)
        ["AAA1", "A0+1", "A10000", "A01", "IF(1,2,A0)", "SUM(A1:A0)", "SUM(AAA1:A1)", "1+SUM(A1,ZZZ5)"]
    it "rejects syntax errors" $
      mapM_ (\s -> parseFormula s `shouldSatisfy` isLeft) ["", "1+", "(1", "1 2", "FOO(1)", "IF(1,2)", "SUM()", "1 $ 2", "\"abc"]

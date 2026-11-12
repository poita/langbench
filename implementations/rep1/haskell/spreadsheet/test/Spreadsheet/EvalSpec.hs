{-# LANGUAGE OverloadedStrings #-}
module Spreadsheet.EvalSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import Test.Hspec

import Spreadsheet
import Spreadsheet.Eval

-- | Evaluate a formula against a fixed set of cells.
ev :: [(Text, Value)] -> Text -> Value
ev cells src = evaluate look (either (error . show) id (parseFormula src))
  where
    table = Map.fromList [(refKey (fromJust (parseCellRef n)), v) | (n, v) <- cells]
    look k = Map.lookup k table

big :: Text
big = "1" <> T.replicate 300 "0"

n :: Double -> Value
n = VNumber

spec :: Spec
spec = do
  describe "arithmetic" $ do
    it "follows precedence" $ do
      ev [] "1+2*3" `shouldBe` n 7
      ev [] "-2*3-4" `shouldBe` n (-10)
      ev [] "--5" `shouldBe` n 5
    it "reports division by zero, including negative zero" $ do
      ev [] "1/0" `shouldBe` VError ErrDivZero
      ev [] "1/(-0)" `shouldBe` VError ErrDivZero
    it "reports non-finite results as #VALUE!" $ do
      ev [] (big <> "*" <> big) `shouldBe` VError ErrValue
    it "refuses strings" $ do
      ev [] "\"5\"+1" `shouldBe` VError ErrValue
      ev [] "-\"a\"" `shouldBe` VError ErrValue
    it "treats empty cells as 0" $ do
      ev [] "Z1+1" `shouldBe` n 1
      ev [] "-Z1&\"x\"" `shouldBe` VText "0x"
  describe "first problem wins" $ do
    it "takes the leftmost error" $ do
      ev [] "A0+1/0" `shouldBe` VError ErrRef
      ev [("A1", VError ErrCycle)] "A1+(1/0)" `shouldBe` VError ErrCycle
      ev [] "(1/0)+\"a\"" `shouldBe` VError ErrDivZero
      ev [] "\"a\"+(1/0)" `shouldBe` VError ErrValue
  describe "concatenation and comparison" $ do
    it "concatenates text forms" $ do
      ev [] "1+2&3" `shouldBe` VText "33"
      ev [] "(Z1)&\"x\"" `shouldBe` VText "x"
      ev [] "1/3&\"\"" `shouldBe` VText "0.3333333333"
    it "compares numbers and strings" $ do
      ev [] "1<2" `shouldBe` n 1
      ev [] "\"a\"<\"b\"" `shouldBe` n 1
      ev [] "\"B\"<\"a\"" `shouldBe` n 1
      ev [] "\"ab\">\"a\"" `shouldBe` n 1
      ev [] "\"a\"=\"A\"" `shouldBe` n 0
    it "compares strings by code point, not UTF-16 unit" $
      ev [] "\"\128512\"<\"\65370\"" `shouldBe` n 0
    it "never converts between numbers and strings" $ do
      ev [] "1=\"1\"" `shouldBe` n 0
      ev [] "1<>\"1\"" `shouldBe` n 1
      ev [] "1<\"1\"" `shouldBe` VError ErrValue
    it "gives empty cells the type of the other operand" $ do
      ev [] "Z1=\"\"" `shouldBe` n 1
      ev [] "Z1=0" `shouldBe` n 1
      ev [] "Z1=Z2" `shouldBe` n 1
      ev [] "Z1<1" `shouldBe` n 1
      ev [] "(Z1)<\"a\"" `shouldBe` n 1
  describe "IF" $ do
    it "evaluates only the selected branch" $ do
      ev [] "IF(1,2,1/0)" `shouldBe` n 2
      ev [] "IF(0,1/0,3)" `shouldBe` n 3
    it "rejects a string condition and passes empty through" $ do
      ev [] "IF(\"x\",1,2)" `shouldBe` VError ErrValue
      ev [] "IF(1,Z1,7)&\"x\"" `shouldBe` VText "x"
      ev [] "IF(Z1,1,2)" `shouldBe` n 2
  describe "aggregates" $ do
    let cells = [("A1", n 1), ("A2", VText "s"), ("A4", n 5)]
    it "skips empty and string cells in ranges" $ do
      ev cells "SUM(A1:A4)" `shouldBe` n 6
      ev cells "COUNT(A1:A4)" `shouldBe` n 2
      ev cells "MIN(A4:A1)" `shouldBe` n 1
      ev cells "MAX(A1:A4)" `shouldBe` n 5
      ev cells "AVG(A1:A4)" `shouldBe` n 3
    it "has defined results for no numbers" $ do
      ev [] "SUM(A1:A3)" `shouldBe` n 0
      ev [] "MIN(A1:A3)" `shouldBe` n 0
      ev [] "MAX(A1:A3)" `shouldBe` n 0
      ev [] "AVG(A1:A3)" `shouldBe` VError ErrDivZero
      ev [] "COUNT((Z1))" `shouldBe` n 0
    it "rejects strings given as expressions but not in ranges" $ do
      ev cells "SUM(A2)" `shouldBe` VError ErrValue
      ev cells "SUM(A1:A2)" `shouldBe` n 1
    it "propagates the first error in row-major order" $
      ev [("A1", VError ErrDivZero), ("B1", VError ErrCycle)] "SUM(A1:B1)" `shouldBe` VError ErrDivZero
    it "sums left to right" $
      ev [] "SUM(10000000000000000,1,1)" `shouldBe` n 1e16
    it "reports non-finite sums and averages as #VALUE!" $ do
      let huge = [("A1", n 1.7e308), ("A2", n 1.7e308)]
      ev huge "SUM(A1:A2)" `shouldBe` VError ErrValue
      ev huge "AVG(A1:A2)" `shouldBe` VError ErrValue
  describe "dependencies" $ do
    let deps s = IntSet.toList (dependencies (either (error . show) id (parseFormula s)))
        keys = map (refKey . fromJust . parseCellRef)
    it "includes both IF branches and every range cell" $ do
      deps "IF(A1,B1,C1)" `shouldBe` keys ["A1", "B1", "C1"]
      deps "SUM(A1:B2)" `shouldBe` keys ["A1", "B1", "A2", "B2"]
    it "is empty after an invalid reference" $
      deps "A1+AAA1" `shouldBe` []

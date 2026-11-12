module Main (main) where

import Test.Hspec

import qualified Spreadsheet.EvalSpec
import qualified Spreadsheet.FormatSpec
import qualified Spreadsheet.GraphSpec
import qualified Spreadsheet.ParserSpec
import qualified Spreadsheet.PropertySpec
import qualified Spreadsheet.ScriptSpec
import qualified Spreadsheet.SheetSpec
import qualified Spreadsheet.TypesSpec

main :: IO ()
main = hspec $ do
  describe "Types" Spreadsheet.TypesSpec.spec
  describe "Format" Spreadsheet.FormatSpec.spec
  describe "Parser" Spreadsheet.ParserSpec.spec
  describe "Eval" Spreadsheet.EvalSpec.spec
  describe "Graph" Spreadsheet.GraphSpec.spec
  describe "Sheet" Spreadsheet.SheetSpec.spec
  describe "Script (SPEC examples)" Spreadsheet.ScriptSpec.spec
  describe "Properties" Spreadsheet.PropertySpec.spec

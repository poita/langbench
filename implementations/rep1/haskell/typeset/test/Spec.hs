module Main (main) where

import Test.Hspec

import qualified Typeset.BreakSpec
import qualified Typeset.GoldenSpec
import qualified Typeset.HyphenationSpec
import qualified Typeset.ParserSpec
import qualified Typeset.SettingsSpec
import qualified Typeset.TableSpec
import qualified Typeset.UnitsSpec

main :: IO ()
main = hspec $ do
  describe "Units" Typeset.UnitsSpec.spec
  describe "Settings" Typeset.SettingsSpec.spec
  describe "Parser" Typeset.ParserSpec.spec
  describe "Hyphenation" Typeset.HyphenationSpec.spec
  describe "Line breaking and setting" Typeset.BreakSpec.spec
  describe "Table columns" Typeset.TableSpec.spec
  describe "Golden documents" Typeset.GoldenSpec.spec

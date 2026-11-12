module Main (main) where

import Test.Hspec

import qualified CommandSpec
import qualified EvalSpec
import qualified GlobSpec
import qualified LexParseSpec
import qualified SessionSpec
import qualified StateSpec

main :: IO ()
main = hspec $ do
  describe "Kiln.Glob" GlobSpec.spec
  describe "Lexer and parser" LexParseSpec.spec
  describe "Evaluator" EvalSpec.spec
  describe "Commands and hashing" CommandSpec.spec
  describe "State file" StateSpec.spec
  describe "Sessions" SessionSpec.spec

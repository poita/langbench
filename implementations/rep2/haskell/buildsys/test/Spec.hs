module Main (main) where

import Test.Hspec

import qualified BuildSpec
import qualified CommandSpec
import qualified EvalSpec
import qualified GlobSpec
import qualified LexerParserSpec
import qualified SessionSpec
import qualified StateSpec

main :: IO ()
main = hspec $ do
  describe "Kiln.Glob" GlobSpec.spec
  describe "Lexer and parser" LexerParserSpec.spec
  describe "Evaluator" EvalSpec.spec
  describe "Commands" CommandSpec.spec
  describe "State file" StateSpec.spec
  describe "Build" BuildSpec.spec
  describe "Session" SessionSpec.spec

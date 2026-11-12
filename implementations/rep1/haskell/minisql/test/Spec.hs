module Main (main) where

import Test.Hspec

import qualified EndToEndSpec
import qualified LexerParserSpec
import qualified ValueSpec

main :: IO ()
main = hspec $ do
  describe "Value and LIKE" ValueSpec.spec
  describe "Lexer and parser" LexerParserSpec.spec
  describe "End to end" EndToEndSpec.spec

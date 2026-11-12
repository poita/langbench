module Main (main) where

import Test.Hspec

import qualified InferSpec
import qualified ParserSpec
import qualified TypeSpec

main :: IO ()
main = hspec $ do
  describe "Type" TypeSpec.spec
  describe "Parser" ParserSpec.spec
  describe "Infer" InferSpec.spec

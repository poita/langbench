module Main (main) where

import Test.Hspec

import qualified DocumentSpec
import qualified JsonSpec
import qualified NumberSpec
import qualified RegexSpec
import qualified UriSpec
import qualified ValidateSpec

main :: IO ()
main = hspec $ do
  describe "JsonSchema.Number" NumberSpec.spec
  describe "JsonSchema.Json" JsonSpec.spec
  describe "JsonSchema.Regex" RegexSpec.spec
  describe "JsonSchema.Uri" UriSpec.spec
  describe "JsonSchema.Validate" ValidateSpec.spec
  describe "JsonSchema.Document" DocumentSpec.spec

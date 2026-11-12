module Main (main) where

import Test.Hspec

import qualified ExamplesSpec
import qualified PropertiesSpec

main :: IO ()
main = hspec $ do
  describe "Examples" ExamplesSpec.spec
  describe "Properties" PropertiesSpec.spec

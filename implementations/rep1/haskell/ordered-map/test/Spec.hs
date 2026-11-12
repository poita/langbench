module Main (main) where

import Test.Hspec

import qualified Data.OrderedMapSpec
import qualified OrderedMap.CommandSpec
import qualified OrderedMap.InterpreterSpec

main :: IO ()
main = hspec $ do
  describe "Data.OrderedMap" Data.OrderedMapSpec.spec
  describe "OrderedMap.Command" OrderedMap.CommandSpec.spec
  describe "OrderedMap.Interpreter" OrderedMap.InterpreterSpec.spec

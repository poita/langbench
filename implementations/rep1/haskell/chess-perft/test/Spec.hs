module Main (main) where

import Test.Hspec

import qualified MoveGenSpec
import qualified PerftSpec
import qualified PositionSpec
import qualified QuerySpec

main :: IO ()
main = hspec $ do
  describe "Position" PositionSpec.spec
  describe "MoveGen" MoveGenSpec.spec
  describe "Perft" PerftSpec.spec
  describe "Query" QuerySpec.spec

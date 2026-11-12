module Main (main) where

import Test.Hspec

import Rubiks.CombinatoricsSpec qualified as Combinatorics
import Rubiks.CoordinatesSpec qualified as Coordinates
import Rubiks.CubeSpec qualified as Cube
import Rubiks.MoveSpec qualified as Move
import Rubiks.SolverSpec qualified as Solver

main :: IO ()
main = hspec $ do
  describe "Rubiks.Move" Move.spec
  describe "Rubiks.Internal.Combinatorics" Combinatorics.spec
  describe "Rubiks.Cube" Cube.spec
  describe "Rubiks.Internal.Coordinates" Coordinates.spec
  describe "Rubiks.Solver" Solver.spec

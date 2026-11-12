module Rubiks.SolverSpec (spec) where

import Data.Array.Unboxed (elems)
import Data.Maybe (fromMaybe)
import Test.Hspec
import Test.QuickCheck

import Rubiks
import Rubiks.Generators
import Rubiks.Internal.Coordinates
import Rubiks.Internal.Phase

-- The tables are built once, on first use, and shared by all examples.
solver :: Solver
solver = newSolver

solvesIn :: Int -> [Move] -> Property
solvesIn limit scr =
  let c = applyMoves scr solved
      s = solveScramble solver scr
   in counterexample (renderMoves s) (isSolved (applyMoves s c) .&&. length s <= limit)

spec :: Spec
spec = do
  it "solves the empty scramble with no moves" $
    solveScramble solver [] `shouldBe` []
  it "solves a single move" $
    solveScramble solver [Move R Clockwise] `shouldSatisfy` \s ->
      isSolved (applyMoves s (applyMove (Move R Clockwise) solved))
  it "solves the superflip within 45 moves" $ do
    let c = applyMoves superflipMoves solved
        s = fromMaybe [] (solve solver c)
    isSolved (applyMoves s c) `shouldBe` True
    length s `shouldSatisfy` (<= maxSolutionLength)
  it "solves random 25-move scrambles in at most 45 moves" $
    withNumTests 200 $ forAll (genScramble 25) (solvesIn maxSolutionLength)
  it "solves arbitrary short scrambles" $
    withNumTests 200 $ forAll genMoves (solvesIn maxSolutionLength)
  it "solves cubes read from facelets" $
    forAll (genScramble 20) $ \scr ->
      case fromFacelets (toFacelets (applyMoves scr solved)) of
        Left e -> counterexample e False
        Right c -> fmap (isSolved . (`applyMoves` c)) (solve solver c) === Just True
  it "refuses unsolvable cubes" $
    solve solver singleFlippedEdge `shouldBe` Nothing

  describe "phases" $ do
    let phasesOf scr = fromMaybe [] (solvePhases solver (applyMoves scr solved))
    it "each phase stays within its optimal bound" $
      withNumTests 100 $ forAll (genScramble 30) $ \scr ->
        map length (phasesOf scr) `isBelow` [7, 10, 13, 15]
    it "each phase only uses its allowed moves" $
      withNumTests 100 $ forAll (genScramble 30) $ \scr ->
        conjoin (zipWith (\ph ms -> property (all (`elem` phaseMoves ph) ms)) phases (phasesOf scr))
    it "each phase ends in the next subgroup" $ do
      let scr = either error id (parseMoves "R U2 F' L D B2 U' R' F2 L2 D' B U R2 F")
          start = applyMoves scr solved
          afterPhase n = applyMoves (concat (take n (phasesOf scr))) start
      edgeOrientation (afterPhase 1) `shouldBe` 0
      (cornerOrientation (afterPhase 2), eSliceEdges (afterPhase 2))
        `shouldBe` (cornerOrientation solved, eSliceEdges solved)
      (cornerCoset (afterPhase 3), mSliceEdges (afterPhase 3))
        `shouldBe` (cornerCoset solved, mSliceEdges solved)
      elems (cornerOri (afterPhase 3)) `shouldBe` replicate 8 0
      isSolved (afterPhase 4) `shouldBe` True
  where
    isBelow xs lims = counterexample (show xs) (length xs == length lims && and (zipWith (<=) xs lims))

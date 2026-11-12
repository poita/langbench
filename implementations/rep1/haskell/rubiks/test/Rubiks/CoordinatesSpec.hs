module Rubiks.CoordinatesSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Data.Array.Unboxed (elems)
import Data.List (nub)

import Rubiks
import Rubiks.Internal.Coordinates
import Rubiks.Internal.Phase

-- | Random sequences of the given moves.
genIn :: [Move] -> Gen [Move]
genIn allowed = sized $ \n -> do
  len <- choose (0, min 30 n)
  vectorOf len (elements allowed)

spec :: Spec
spec = do
  describe "coordinate sizes" $
    it "match the specification" $
      map phaseSize phases `shouldBe` [2048, 2187 * 495, 420 * 70, 96 * 24 ^ (3 :: Int)]

  describe "decode and encode" $ do
    it "round-trip every coordinate value" $ do
      let check n dec enc = mapM_ (\i -> enc (dec i) `shouldBe` i) [0 .. n - 1 :: Int]
      check edgeOrientationCount edgeOrientationCube edgeOrientation
      check cornerOrientationCount cornerOrientationCube cornerOrientation
      check eSliceEdgesCount eSliceEdgesCube eSliceEdges
      check cornerCosetCount cornerCosetCube cornerCoset
      check mSliceEdgesCount mSliceEdgesCube mSliceEdges
      check cornerHalfTurnCount cornerHalfTurnCube cornerHalfTurn
      check edgePermutationsCount edgePermutationsCube edgePermutations
    it "give 96 distinct half-turn corner permutations" $
      length (nub [elems (cornerPerm (cornerHalfTurnCube i)) | i <- [0 .. 95]]) `shouldBe` 96

  describe "phase transitions" $ do
    let (p1, p2, p3, p4) = (phases !! 0, phases !! 1, phases !! 2, phases !! 3)
    -- The phase i coordinate is only defined for cubes reached with the moves
    -- of phase i-1, which always include the moves of phase i.
    let agrees ph reachedBy = property $ forAll (genIn reachedBy) $ \scr ->
          let c = applyMoves scr solved
           in [phaseStep ph (phaseEncode ph c) i | i <- [0 .. length (phaseMoves ph) - 1]]
                === [phaseEncode ph (applyMove m c) | m <- phaseMoves ph]
    it "phase 1 agrees with the cube" $ agrees p1 allMoves
    it "phase 2 agrees with the cube" $ agrees p2 (phaseMoves p2)
    it "phase 3 agrees with the cube" $ agrees p3 (phaseMoves p3)
    it "phase 4 agrees with the cube" $ agrees p4 (phaseMoves p4)
    it "phase 2 coordinates stay in the phase 1 goal coset" $
      property $ forAll (genIn (phaseMoves p2)) $ \scr ->
        edgeOrientation (applyMoves scr solved) === edgeOrientation solved
    it "phase 3 coordinates stay in the phase 2 goal coset" $
      property $ forAll (genIn (phaseMoves p3)) $ \scr ->
        let c = applyMoves scr solved
         in (cornerOrientation c, eSliceEdges c) === (cornerOrientation solved, eSliceEdges solved)
    it "phase 4 coordinates stay in the phase 3 goal coset" $
      property $ forAll (genIn (phaseMoves p4)) $ \scr ->
        let c = applyMoves scr solved
         in (cornerCoset c, mSliceEdges c) === (cornerCoset solved, mSliceEdges solved)

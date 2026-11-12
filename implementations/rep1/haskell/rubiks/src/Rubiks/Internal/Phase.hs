-- |
-- Module      : Rubiks.Internal.Phase
-- Description : The four Thistlethwaite phases.
--
-- A 'Phase' bundles the move set, the coordinate and its transition function
-- for one stage of the algorithm.  See "Rubiks.Internal.Coordinates" for
-- the coordinates.
module Rubiks.Internal.Phase
  ( Phase (..)
  , phases
  , phaseGoal
  ) where

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray)

import Rubiks.Cube
import Rubiks.Internal.Coordinates
import Rubiks.Move

-- | One phase of the algorithm.
data Phase = Phase
  { phaseName :: String
  , phaseMoves :: [Move]
    -- ^ The moves allowed in this phase; indices into this list are used by
    -- 'phaseStep'.
  , phaseSize :: !Int
    -- ^ Number of values of the coordinate.
  , phaseEncode :: Cube -> Int
    -- ^ Read the coordinate off a cube.  Precondition: the cube is in the
    -- subgroup the previous phase reaches.
  , phaseStep :: Int -> Int -> Int
    -- ^ @phaseStep s i@: the coordinate after the @i@-th move of
    -- 'phaseMoves'.
  }

-- | The coordinate value of the goal: that of the solved cube.
phaseGoal :: Phase -> Int
phaseGoal p = phaseEncode p solved

-- | The four phases, in order.
phases :: [Phase]
phases = [phase1, phase2, phase3, phase4]

at :: UArray Int Int -> Int -> Int
at = unsafeAt
{-# INLINE at #-}

-- | Phase 1: orient all edges (reach @<U,D,L,R,F2,B2>@).
phase1 :: Phase
phase1 =
  Phase
    { phaseName = "edge orientation"
    , phaseMoves = ms
    , phaseSize = edgeOrientationCount
    , phaseEncode = edgeOrientation
    , phaseStep = \s i -> at table (s * k + i)
    }
  where
    ms = allMoves
    k = length ms
    table = buildMoveTable edgeOrientationCount ms edgeOrientationCube edgeOrientation

-- | Phase 2: orient corners and put the middle-layer edges in the middle
-- layer (reach @<U,D,L2,R2,F2,B2>@).
phase2 :: Phase
phase2 =
  Phase
    { phaseName = "corner orientation and E-slice"
    , phaseMoves = ms
    , phaseSize = cornerOrientationCount * eSliceEdgesCount
    , phaseEncode = \c -> cornerOrientation c * eSliceEdgesCount + eSliceEdges c
    , phaseStep = \s i ->
        let (co, sl) = s `quotRem` eSliceEdgesCount
         in at coTable (co * k + i) * eSliceEdgesCount + at slTable (sl * k + i)
    }
  where
    ms = [m | m@(Move f t) <- allMoves, f `notElem` [F, B] || t == Half]
    k = length ms
    coTable = buildMoveTable cornerOrientationCount ms cornerOrientationCube cornerOrientation
    slTable = buildMoveTable eSliceEdgesCount ms eSliceEdgesCube eSliceEdges

-- | Phase 3: put corners in the half-turn group's orbits and each edge in
-- its own slice (reach @<U2,D2,L2,R2,F2,B2>@).
phase3 :: Phase
phase3 =
  Phase
    { phaseName = "corner tetrads and M-slice"
    , phaseMoves = ms
    , phaseSize = cornerCosetCount * mSliceEdgesCount
    , phaseEncode = \c -> cornerCoset c * mSliceEdgesCount + mSliceEdges c
    , phaseStep = \s i ->
        let (cc, me) = s `quotRem` mSliceEdgesCount
         in at ccTable (cc * k + i) * mSliceEdgesCount + at meTable (me * k + i)
    }
  where
    ms = [m | m@(Move f t) <- allMoves, f `elem` [U, D] || t == Half]
    k = length ms
    ccTable = buildMoveTable cornerCosetCount ms cornerCosetCube cornerCoset
    meTable = buildMoveTable mSliceEdgesCount ms mSliceEdgesCube mSliceEdges

-- | Phase 4: solve the cube with half turns.
phase4 :: Phase
phase4 =
  Phase
    { phaseName = "half turns"
    , phaseMoves = ms
    , phaseSize = cornerHalfTurnCount * edgePermutationsCount
    , phaseEncode = \c -> cornerHalfTurn c * edgePermutationsCount + edgePermutations c
    , phaseStep = \s i ->
        let (cp, ep) = s `quotRem` edgePermutationsCount
         in at cpTable (cp * k + i) * edgePermutationsCount + at epTable (ep * k + i)
    }
  where
    ms = [m | m@(Move _ t) <- allMoves, t == Half]
    k = length ms
    cpTable = buildMoveTable cornerHalfTurnCount ms cornerHalfTurnCube cornerHalfTurn
    epTable = buildMoveTable edgePermutationsCount ms edgePermutationsCube edgePermutations

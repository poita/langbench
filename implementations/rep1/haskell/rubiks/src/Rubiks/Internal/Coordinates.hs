-- |
-- Module      : Rubiks.Internal.Coordinates
-- Description : Coordinates identifying a cube's coset in each phase.
--
-- Thistlethwaite's algorithm walks down the chain of subgroups
--
-- > G0 = <U,D,L,R,F,B>  >  G1 = <U,D,L,R,F2,B2>  >  G2 = <U,D,L2,R2,F2,B2>
-- >    >  G3 = <U2,D2,L2,R2,F2,B2>  >  G4 = {1}
--
-- Phase @i@ brings the cube into @G_i@ using only moves of @G_(i-1)@.  Each
-- phase has a coordinate that identifies the cube's coset of @G_i@ in
-- @G_(i-1)@ (phase 4: the element itself), such that the coordinate after a
-- move depends only on the coordinate before it.  The solved cube has the
-- coordinate of the goal coset.
--
-- Every coordinate here comes with a function reading it off a 'Cube' and a
-- function building a /representative/ cube for a coordinate value, which
-- is enough to compute move tables by brute force.  The representative's
-- other components are arbitrary (usually solved); this is sound because each
-- coordinate evolves independently of them.
--
-- This module is internal and its API may change.
module Rubiks.Internal.Coordinates
  ( -- * Phase 1: edge orientation
    edgeOrientation
  , edgeOrientationCube
  , edgeOrientationCount
    -- * Phase 2: corner orientation and E-slice edges
  , cornerOrientation
  , cornerOrientationCube
  , cornerOrientationCount
  , eSliceEdges
  , eSliceEdgesCube
  , eSliceEdgesCount
    -- * Phase 3: corner coset and M-slice edges
  , cornerCoset
  , cornerCosetCube
  , cornerCosetCount
  , mSliceEdges
  , mSliceEdgesCube
  , mSliceEdgesCount
    -- * Phase 4: half-turn corner permutation and edge permutations
  , cornerHalfTurn
  , cornerHalfTurnCube
  , cornerHalfTurnCount
  , edgePermutations
  , edgePermutationsCube
  , edgePermutationsCount
    -- * Move tables
  , buildMoveTable
  ) where

import Data.Array (Array)
import Data.Array qualified as A
import Data.Array.Unboxed (UArray, elems, listArray, (!))
import Data.Map.Strict qualified as M
import Data.Set qualified as S

import Rubiks.Cube
import Rubiks.Internal.Combinatorics
import Rubiks.Move

-- | @buildMoveTable n moves decode encode@ is the flattened table with
-- @table ! (s * length moves + i)@ the coordinate reached from coordinate @s@
-- by the @i@-th move.
buildMoveTable :: Int -> [Move] -> (Int -> Cube) -> (Cube -> Int) -> UArray Int Int
buildMoveTable n ms decode encode =
  listArray (0, n * length ms - 1) [encode (applyMove m (decode s)) | s <- [0 .. n - 1], m <- ms]

withEdges :: [Int] -> [Int] -> Cube
withEdges ep eo = solved {edgePerm = listArray (0, 11) ep, edgeOri = listArray (0, 11) eo}

withCorners :: [Int] -> [Int] -> Cube
withCorners cp co = solved {cornerPerm = listArray (0, 7) cp, cornerOri = listArray (0, 7) co}

-- ---------------------------------------------------------------------------
-- Phase 1

-- | Number of values of 'edgeOrientation'.
edgeOrientationCount :: Int
edgeOrientationCount = 2 ^ (11 :: Int)

-- | Orientation of edges 0-10 as a binary number (the twelfth is determined).
edgeOrientation :: Cube -> Int
edgeOrientation c = foldr (\o acc -> 2 * acc + o) 0 (take 11 (elems (edgeOri c)))

-- | A cube with the given edge orientation and everything else solved.
edgeOrientationCube :: Int -> Cube
edgeOrientationCube n = withEdges [0 .. 11] (bits ++ [sum bits `mod` 2])
  where
    bits = [(n `div` 2 ^ i) `mod` 2 | i <- [0 .. 10 :: Int]]

-- ---------------------------------------------------------------------------
-- Phase 2

-- | Number of values of 'cornerOrientation'.
cornerOrientationCount :: Int
cornerOrientationCount = 3 ^ (7 :: Int)

-- | Twist of corners 0-6 as a base-3 number (the eighth is determined).
cornerOrientation :: Cube -> Int
cornerOrientation c = foldr (\o acc -> 3 * acc + o) 0 (take 7 (elems (cornerOri c)))

-- | A cube with the given corner twists and everything else solved.
cornerOrientationCube :: Int -> Cube
cornerOrientationCube n = withCorners [0 .. 7] (digits ++ [(negate (sum digits)) `mod` 3])
  where
    digits = [(n `div` 3 ^ i) `mod` 3 | i <- [0 .. 6 :: Int]]

-- | Number of values of 'eSliceEdges'.
eSliceEdgesCount :: Int
eSliceEdgesCount = choose 12 4

-- | Which four positions hold the middle-layer edges (pieces 8-11).
eSliceEdges :: Cube -> Int
eSliceEdges c = rankSubset [p | (p, e) <- zip [0 ..] (elems (edgePerm c)), e >= 8]

-- | A cube whose middle-layer edges are at the given positions.
eSliceEdgesCube :: Int -> Cube
eSliceEdgesCube r = withEdges (merge [0 .. 11] (unrankSubset 12 4 r) [8 .. 11] [0 .. 7]) (replicate 12 0)

-- ---------------------------------------------------------------------------
-- Phase 3

-- | The 96 corner permutations (position to piece) reachable with half turns,
-- as lists.
halfTurnCornerGroup :: Array Int [Int]
halfTurnCornerGroup = A.listArray (0, length gs - 1) gs
  where
    gs = S.toList (closure [cp (moveCube (Move f Half)) | f <- allFaces] [0 .. 7])
    cp = elems . cornerPerm

-- | Close a set of permutations under right-multiplication by the generators.
closure :: [[Int]] -> [Int] -> S.Set [Int]
closure gens start = go (S.singleton start) [start]
  where
    go seen [] = seen
    go seen (p : queue) =
      let new = [q | g <- gens, let q = map (p !!) g, not (S.member q seen)]
          newSet = S.fromList new
       in go (S.union seen newSet) (queue ++ S.toList newSet)

halfTurnIndex :: M.Map [Int] Int
halfTurnIndex = M.fromList [(g, i) | (i, g) <- A.assocs halfTurnCornerGroup]

-- | Number of values of 'cornerHalfTurn'.
cornerHalfTurnCount :: Int
cornerHalfTurnCount = 96

-- | Index of the corner permutation within the half-turn group (96 values);
-- only meaningful for cubes in @G3@.
cornerHalfTurn :: Cube -> Int
cornerHalfTurn c = case M.lookup (elems (cornerPerm c)) halfTurnIndex of
  Just i -> i
  Nothing -> error "cornerHalfTurn: corner permutation not in the half-turn group"

-- | A cube with the given corner permutation and everything else solved.
cornerHalfTurnCube :: Int -> Cube
cornerHalfTurnCube i = withCorners (halfTurnCornerGroup A.! i) (replicate 8 0)

-- | Canonical representative of the coset @H p@ of a corner permutation
-- (@H@ the half-turn group, acting on piece labels).
cosetKey :: [Int] -> [Int]
cosetKey p = minimum [map (h !) p | h <- halfTurnRelabellings]

halfTurnRelabellings :: [UArray Int Int]
halfTurnRelabellings = [listArray (0, 7) g | g <- A.elems halfTurnCornerGroup]

-- | The 420 cosets, each represented by its canonical permutation, indexed
-- in breadth-first order from the identity under G2's corner moves.
cosetReps :: Array Int [Int]
cosetReps = A.listArray (0, length reps - 1) reps
  where
    gens = [elems (cornerPerm (moveCube m)) | m <- g2Moves]
    start = cosetKey [0 .. 7]
    reps = go (S.singleton start) [start] []
    go _ [] acc = reverse acc
    go seen (p : queue) acc =
      let new = S.toList (S.fromList [q | g <- gens, let q = cosetKey (map (p !!) g)] `S.difference` seen)
       in go (foldr S.insert seen new) (queue ++ new) (p : acc)

cosetIndex :: M.Map [Int] Int
cosetIndex = M.fromList [(r, i) | (i, r) <- A.assocs cosetReps]

-- | The moves of @G2@: U, D turns and half turns of the other faces.
g2Moves :: [Move]
g2Moves = [m | m@(Move f t) <- allMoves, f `elem` [U, D] || t == Half]

-- | Number of values of 'cornerCoset'.
cornerCosetCount :: Int
cornerCosetCount = 420

-- | The coset of the corner permutation modulo the half-turn group (420
-- values); only meaningful for cubes in @G2@.
cornerCoset :: Cube -> Int
cornerCoset c = case M.lookup (cosetKey (elems (cornerPerm c))) cosetIndex of
  Just i -> i
  Nothing -> error "cornerCoset: corner permutation not reachable in G2"

-- | A cube with a corner permutation in the given coset and everything else
-- solved.
cornerCosetCube :: Int -> Cube
cornerCosetCube i = withCorners (cosetReps A.! i) (replicate 8 0)

-- | Number of values of 'mSliceEdges'.
mSliceEdgesCount :: Int
mSliceEdgesCount = choose 8 4

-- | Which four of the eight U/D-layer positions hold M-slice pieces (the
-- pieces UF, UB, DF, DB, i.e. the odd-numbered ones); only meaningful when
-- the middle-layer edges are in the middle layer.
mSliceEdges :: Cube -> Int
mSliceEdges c = rankSubset [p | (p, e) <- zip [0 .. 7] (elems (edgePerm c)), odd e]

-- | A cube with the middle-layer edges home and M-slice pieces in the given
-- U/D-layer positions.
mSliceEdgesCube :: Int -> Cube
mSliceEdgesCube r =
  withEdges (merge [0 .. 7] (unrankSubset 8 4 r) [1, 3, 5, 7] [0, 2, 4, 6] ++ [8 .. 11]) (replicate 12 0)

-- | @merge positions slots ins outs@ lists, for each position in order, the
-- next element of @ins@ if the position is one of @slots@ and otherwise the
-- next element of @outs@.
merge :: [Int] -> [Int] -> [Int] -> [Int] -> [Int]
merge [] _ _ _ = []
merge (p : ps) slots ins outs
  | p `elem` slots, (x : ins') <- ins = x : merge ps slots ins' outs
  | (x : outs') <- outs = x : merge ps slots ins outs'
  | otherwise = []

-- ---------------------------------------------------------------------------
-- Phase 4

-- | Number of values of 'edgePermutations'.
edgePermutationsCount :: Int
edgePermutationsCount = 24 * 24 * 24

-- | The permutations of the M-slice, S-slice and E-slice edges within their
-- own four positions, combined into one number; only meaningful for cubes in
-- @G3@.
edgePermutations :: Cube -> Int
edgePermutations c = (rank [1, 3, 5, 7] 1 * 24 + rank [0, 2, 4, 6] 0) * 24 + rank [8 .. 11] 8
  where
    ep = edgePerm c
    -- permutation of the pieces (base + 2k) found at positions (base + 2k)
    rank poss base = rankPermutation [normalise base (ep ! p) | p <- poss]
    normalise base e
      | base == 8 = e - 8
      | otherwise = (e - base) `div` 2

-- | A cube with the given edge permutations and everything else solved.
edgePermutationsCube :: Int -> Cube
edgePermutationsCube n = withEdges ep (replicate 12 0)
  where
    (rest, rE) = n `divMod` 24
    (rM, rS) = rest `divMod` 24
    mPerm = [2 * x + 1 | x <- unrankPermutation 4 rM]
    sPerm = [2 * x | x <- unrankPermutation 4 rS]
    ePerm = [8 + x | x <- unrankPermutation 4 rE]
    -- positions 0..7: even positions take S pieces, odd positions M pieces
    ep = concat [[s, m] | (s, m) <- zip sPerm mPerm] ++ ePerm

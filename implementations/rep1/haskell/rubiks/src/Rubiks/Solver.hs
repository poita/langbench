-- |
-- Module      : Rubiks.Solver
-- Description : Thistlethwaite's four-phase solver.
--
-- Building a 'Solver' fills four exact distance tables (one per phase) by
-- breadth-first search from each phase's goal; this is done once and lazily,
-- the first time the solver is used.  Solving a cube is then a greedy descent:
-- in each phase, repeatedly take any allowed move that gets one step closer to
-- the goal.  Because the tables are exact, each phase is optimal and a
-- solution has at most 7 + 10 + 13 + 15 = 45 moves.
module Rubiks.Solver
  ( Solver
  , newSolver
  , solve
  , solvePhases
  , maxSolutionLength
  ) where

import Data.Array.Unboxed ((!))

import Rubiks.Cube
import Rubiks.Internal.Phase
import Rubiks.Internal.Table
import Rubiks.Move

-- | Distance tables for the four phases.
newtype Solver = Solver [(Phase, DistanceTable)]

-- | Build the distance tables.  Evaluation is lazy: nothing is computed until
-- a cube is solved, and the tables are then shared by all further solves.
newSolver :: Solver
newSolver = Solver [(p, table p) | p <- phases]
  where
    table p = distanceTable (phaseSize p) (phaseGoal p) (length (phaseMoves p)) (phaseStep p)

-- | The most moves 'solve' can return: 7 + 10 + 13 + 15.
maxSolutionLength :: Int
maxSolutionLength = 45

-- | Solve a cube, returning moves that take it to the solved state, or
-- 'Nothing' if the cube cannot be solved (see 'isSolvable').  Adjacent turns
-- of one face at a phase boundary are merged (see 'mergeMoves'), so the
-- result is never longer than 'maxSolutionLength'.
solve :: Solver -> Cube -> Maybe [Move]
solve solver = fmap (mergeMoves . concat) . solvePhases solver

-- | Like 'solve', but the moves of each of the four phases separately.
solvePhases :: Solver -> Cube -> Maybe [[Move]]
solvePhases (Solver stages) cube0
  | not (isSolvable cube0) = Nothing
  | otherwise = Just (go stages cube0)
  where
    go [] _ = []
    go ((phase, dist) : rest) cube =
      let ms = descend phase dist (phaseEncode phase cube)
       in ms : go rest (applyMoves ms cube)

-- | Greedy descent through a distance table from a coordinate value.
descend :: Phase -> DistanceTable -> Int -> [Move]
descend phase dist = go
  where
    moves = zip [0 ..] (phaseMoves phase)
    go s
      | d == 0 = []
      | d == unreached = error ("Rubiks.Solver: unreachable state in phase " ++ phaseName phase)
      | otherwise = case [(m, s') | (i, m) <- moves, let s' = phaseStep phase s i, dist ! s' == d - 1] of
          (m, s') : _ -> m : go s'
          [] -> error "Rubiks.Solver: inconsistent distance table"
      where
        d = dist ! s

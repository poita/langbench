-- |
-- Module      : Rubiks
-- Description : A Rubik's cube solver based on Thistlethwaite's algorithm.
--
-- > import Rubiks
-- >
-- > main :: IO ()
-- > main = do
-- >   let Right scramble = parseMoves "R U R' U' F2 D L"
-- >       cube = applyMoves scramble solved
-- >       Just solution = solve newSolver cube
-- >   putStrLn (renderMoves solution)
-- >   print (isSolved (applyMoves solution cube))   -- True
--
-- See "Rubiks.Move" for moves and notation, "Rubiks.Cube" for the cube model,
-- "Rubiks.Facelet" for the sticker model, and "Rubiks.Solver" for the solver.
module Rubiks
  ( module Rubiks.Move
  , module Rubiks.Cube
  , module Rubiks.Solver
  , module Rubiks.Facelet
  , solveScramble
  ) where

import Rubiks.Cube
import Rubiks.Facelet
import Rubiks.Move
import Rubiks.Solver

-- | Apply a scramble to a solved cube and solve it.
solveScramble :: Solver -> [Move] -> [Move]
solveScramble solver scramble =
  case solve solver (applyMoves scramble solved) of
    Just s -> s
    Nothing -> error "solveScramble: unsolvable cube"  -- impossible: moves preserve solvability

-- |
-- Module      : Sat
-- Description : A CDCL SAT solver for formulas in conjunctive normal form.
--
-- > import Sat
-- >
-- > main :: IO ()
-- > main = case solve (CNF 3 [[1, -2], [2, 3], [-1, -3]]) of
-- >   Unsat   -> putStrLn "unsatisfiable"
-- >   Sat m   -> print (modelLiterals m)
--
-- The module re-exports the types of "Sat.Types", the DIMACS reader/writer
-- of "Sat.Dimacs" and the pure entry points of "Sat.Solver". Use
-- "Sat.Solver" directly for the incremental 'Control.Monad.ST.ST' interface
-- and for tuning.
module Sat
  ( -- * Solving
    solve
  , solveWith
  , Config (..)
  , defaultConfig
    -- * Formulas and answers
  , module Sat.Types
    -- * DIMACS
  , parseDimacs
  , renderCNF
  , renderResult
  ) where

import Sat.Dimacs
import Sat.Solver (Config (..), defaultConfig, solveCNF, solveCNFWith)
import Sat.Types

-- | Decide a formula. A 'Sat' answer carries a model satisfying every clause.
solve :: CNF -> Result
solve = solveCNF

-- | 'solve' with explicit tuning parameters.
solveWith :: Config -> CNF -> Result
solveWith = solveCNFWith

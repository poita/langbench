-- |
-- Module      : Sat
-- Description : A CDCL SAT solver for DIMACS CNF formulas.
--
-- The one-stop import.  A formula is a 'CNF' (a variable count and a list of
-- clauses of non-zero 'Int' literals); 'solve' decides it:
--
-- >>> import Sat
-- >>> solve (CNF 3 [[1, -2], [2, 3]]) /= Unsatisfiable
-- True
-- >>> solve (CNF 1 [[1], [-1]])
-- Unsatisfiable
--
-- Text in and out is handled by "Sat.Dimacs":
--
-- >>> import qualified Data.ByteString.Char8 as BS
-- >>> either error (renderResult . solve) (parseDimacs (BS.pack "p cnf 1 1\n1 0\n"))
-- SAT
-- 1 0
module Sat
  ( -- * Formulas and results
    module Sat.Types
    -- * Solving
  , solve
    -- * DIMACS input and output
  , parseDimacs
  , renderResult
  ) where

import Sat.Dimacs (parseDimacs, renderResult)
import Sat.Solver (solve)
import Sat.Types

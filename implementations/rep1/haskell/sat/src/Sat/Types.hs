-- |
-- Module      : Sat.Types
-- Description : Core data types shared by the parser, the solver and the CLI.
--
-- Formulas use the DIMACS convention for literals: the positive integer @k@
-- means "variable @k@ is true" and @-k@ means "variable @k@ is false";
-- variables are numbered @1..V@ and @0@ is never a literal.
module Sat.Types
  ( Lit
  , Clause
  , CNF (..)
  , Model
  , Result (..)
  , modelValue
  , modelLiterals
  , satisfiesClause
  , satisfies
  ) where

import Data.Array.Unboxed (UArray, (!), elems)

-- | A DIMACS literal: a non-zero integer, @-v@ being the negation of @v@.
type Lit = Int

-- | A disjunction of literals. The empty clause is unsatisfiable.
type Clause = [Lit]

-- | A formula in conjunctive normal form.
data CNF = CNF
  { cnfNumVars :: !Int
    -- ^ Number of variables @V@; every literal lies in @[-V..-1] ++ [1..V]@.
  , cnfClauses :: [Clause]
    -- ^ The clauses, in input order.
  } deriving (Eq, Show)

-- | A total assignment, indexed by variable @1..V@ (@True@ = true).
type Model = UArray Int Bool

-- | The outcome of a solver run.
data Result
  = Unsat          -- ^ The formula has no model.
  | Sat !Model     -- ^ The formula is satisfiable; here is a model.
  deriving (Eq, Show)

-- | Truth value of a literal under a model.
modelValue :: Model -> Lit -> Bool
modelValue m l
  | l > 0     = m ! l
  | otherwise = not (m ! negate l)

-- | The model as one literal per variable, in increasing variable order
-- (@i@ if variable @i@ is true, @-i@ otherwise).
modelLiterals :: Model -> [Lit]
modelLiterals m = [ if b then i else negate i | (i, b) <- zip [1 ..] (elems m) ]

-- | Does the model satisfy the clause?
satisfiesClause :: Model -> Clause -> Bool
satisfiesClause m = any (modelValue m)

-- | Does the model satisfy every clause of the formula?
satisfies :: Model -> CNF -> Bool
satisfies m = all (satisfiesClause m) . cnfClauses

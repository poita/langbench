-- |
-- Module      : Sat.Types
-- Description : Core data types: literals, formulas, models, results.
--
-- Literals use the DIMACS convention: variable @k@ (with @1 <= k <= V@) is
-- the positive literal @k@ and its negation is @-k@; @0@ is never a literal.
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

import Data.Array.Unboxed (UArray, assocs, (!))

-- | A DIMACS literal: a non-zero 'Int'.
type Lit = Int

-- | A disjunction of literals.  May be empty (unsatisfiable), contain
-- duplicates, or contain a literal together with its negation.
type Clause = [Lit]

-- | A formula in conjunctive normal form.
data CNF = CNF
  { cnfNumVars :: !Int       -- ^ number of variables @V@; variables are @1..V@
  , cnfClauses :: [Clause]   -- ^ the clauses, in input order
  } deriving (Eq, Show)

-- | A total assignment: the value of every variable @1..V@.
type Model = UArray Int Bool

-- | Outcome of a satisfiability check.
data Result
  = Satisfiable Model   -- ^ a model covering every variable
  | Unsatisfiable
  deriving (Eq, Show)

-- | Truth value of a literal under a model.
modelValue :: Model -> Lit -> Bool
modelValue m l
  | l > 0 = m ! l
  | otherwise = not (m ! negate l)

-- | The model as one literal per variable, in increasing variable order.
modelLiterals :: Model -> [Lit]
modelLiterals m = [if b then v else negate v | (v, b) <- assocs m]

-- | Does the model satisfy the clause?
satisfiesClause :: Model -> Clause -> Bool
satisfiesClause m = any (modelValue m)

-- | Does the model satisfy every clause of the formula?
satisfies :: Model -> CNF -> Bool
satisfies m = all (satisfiesClause m) . cnfClauses

-- |
-- Module      : Datalog.Syntax
-- Description : Abstract syntax of Datalog programs.
--
-- The types in this module describe a parsed program. Predicate names and
-- constants are ASCII 'ByteString's / integers; a predicate is identified by
-- its name /and/ arity (see 'PredKey').
module Datalog.Syntax
  ( Const (..)
  , Term (..)
  , Atom (..)
  , CmpOp (..)
  , Literal (..)
  , Rule (..)
  , Clause (..)
  , Program
  , PredKey
  , atomKey
  , clauseRules
  , clauseQueries
  , evalCmp
  ) where

import Data.ByteString (ByteString)

-- | A constant. The derived 'Ord' instance is exactly the total order of the
-- specification: every integer precedes every symbol, integers compare
-- numerically and symbols compare bytewise (a proper prefix sorts first).
data Const
  = CInt !Int
  | CSym !ByteString
  deriving (Eq, Ord, Show)

-- | An argument of an atom or comparison.
data Term
  = TConst !Const
  | TVar !ByteString  -- ^ a named variable (@X@, @Foo_1@)
  | TAnon             -- ^ the anonymous variable @_@; every occurrence is fresh
  deriving (Eq, Show)

-- | @name(arg1, ..., argN)@ with @N >= 1@.
data Atom = Atom
  { atomPred :: !ByteString
  , atomArgs :: [Term]
  }
  deriving (Eq, Show)

-- | Comparison operators.
data CmpOp = OpLt | OpLe | OpGt | OpGe | OpEq | OpNe
  deriving (Eq, Show)

-- | A body literal.
data Literal
  = Pos Atom               -- ^ positive atom
  | Neg Atom               -- ^ @not atom@
  | Cmp CmpOp Term Term    -- ^ built-in comparison
  deriving (Eq, Show)

-- | @head :- body.@ A fact is a rule with an empty body.
data Rule = Rule
  { ruleHead :: Atom
  , ruleBody :: [Literal]
  }
  deriving (Eq, Show)

-- | A top-level clause: a rule (or fact) or a query @?- atom.@
data Clause
  = ClauseRule Rule
  | ClauseQuery Atom
  deriving (Eq, Show)

-- | A program is a sequence of clauses, in source order.
type Program = [Clause]

-- | A predicate is identified by its name together with its arity.
type PredKey = (ByteString, Int)

-- | The predicate an atom refers to.
atomKey :: Atom -> PredKey
atomKey (Atom p as) = (p, length as)

-- | All rules and facts, in source order.
clauseRules :: Program -> [Rule]
clauseRules prog = [r | ClauseRule r <- prog]

-- | All queries, in source order.
clauseQueries :: Program -> [Atom]
clauseQueries prog = [q | ClauseQuery q <- prog]

-- | Decide a comparison between two constants under the total order.
evalCmp :: Ord a => CmpOp -> a -> a -> Bool
evalCmp op a b = case op of
  OpLt -> a < b
  OpLe -> a <= b
  OpGt -> a > b
  OpGe -> a >= b
  OpEq -> a == b
  OpNe -> a /= b

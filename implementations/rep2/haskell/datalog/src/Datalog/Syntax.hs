-- |
-- Module      : Datalog.Syntax
-- Description : Abstract syntax of Datalog programs.
--
-- The types here mirror the grammar: a 'Program' is a list of 'Rule's
-- (facts are rules with an empty body) and a list of query 'Atom's in
-- source order.
module Datalog.Syntax
  ( Const (..)
  , Term (..)
  , Atom (..)
  , CmpOp (..)
  , Literal (..)
  , Rule (..)
  , Program (..)
  , Predicate (..)
  , atomPredicate
  , isFact
  , renderConst
  , renderAtom
  ) where

import Data.List (intercalate)

-- | A constant. The derived 'Ord' is the language's total order: every
-- integer is below every symbol, integers compare numerically and symbols
-- compare lexicographically by ASCII value (a proper prefix sorts first).
data Const
  = CInt !Int
  | CSym !String
  deriving (Eq, Ord, Show)

-- | A term in an atom or comparison.
data Term
  = TConst !Const
  | TVar !String   -- ^ a named variable (scoped to its clause)
  | TAnon          -- ^ @_@: a fresh variable occurring nowhere else
  deriving (Eq, Ord, Show)

-- | @name(t1, …, tn)@.
data Atom = Atom
  { atomName :: !String
  , atomArgs :: [Term]
  } deriving (Eq, Ord, Show)

-- | Comparison operators usable in rule bodies.
data CmpOp = OpLt | OpLe | OpGt | OpGe | OpEq | OpNe
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A body literal.
data Literal
  = Pos Atom                -- ^ positive atom
  | Neg Atom                -- ^ @not atom@
  | Cmp CmpOp Term Term     -- ^ built-in comparison
  deriving (Eq, Ord, Show)

-- | @head :- body.@ A fact is a rule with an empty body.
data Rule = Rule
  { ruleHead :: Atom
  , ruleBody :: [Literal]
  } deriving (Eq, Ord, Show)

-- | A parsed program: all facts and rules in input order, and the queries
-- in input order.
data Program = Program
  { progRules   :: [Rule]
  , progQueries :: [Atom]
  } deriving (Eq, Show)

-- | A predicate is identified by its name and arity together.
data Predicate = Predicate
  { predName  :: !String
  , predArity :: !Int
  } deriving (Eq, Ord, Show)

-- | The predicate an atom refers to.
atomPredicate :: Atom -> Predicate
atomPredicate (Atom n as) = Predicate n (length as)

-- | Is this rule a fact (empty body)?
isFact :: Rule -> Bool
isFact = null . ruleBody

-- | Canonical textual form of a constant.
renderConst :: Const -> String
renderConst (CInt n) = show n
renderConst (CSym s) = s

-- | @p(v1, v2, …)@ for a ground tuple of the given predicate name.
renderAtom :: String -> [Const] -> String
renderAtom name vs = name ++ "(" ++ intercalate ", " (map renderConst vs) ++ ")"

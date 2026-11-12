-- |
-- Module      : Datalog.Plan
-- Description : Compilation of rules into join plans.
--
-- A rule whose predicates and constants are already numbered ('CRule') is
-- turned into a 'Plan': a sequence of steps forming an indexed nested-loop
-- join. The join order is chosen as the specification demands: the delta atom
-- (if any) first, then repeatedly the positive atom with the most bound
-- arguments (constants or variables bound by earlier atoms), ties broken by
-- body order. Negated atoms and comparisons are scheduled as soon as all of
-- their variables are bound.
module Datalog.Plan
  ( PredId
  , Operand (..)
  , CAtom (..)
  , CRule (..)
  , Level (..)
  , Source (..)
  , Step (..)
  , Plan (..)
  , planRule
  , planIndexes
  , isIdentityPerm
  ) where

import qualified Data.IntSet as IS
import Data.List (partition)

import Datalog.Syntax (CmpOp)

-- | Dense predicate number.
type PredId = Int

-- | A compiled term: a constant (by its rank in the constant order) or a
-- variable slot of the rule.
data Operand
  = OConst !Int
  | OVar !Int
  deriving (Eq, Show)

-- | A compiled atom.
data CAtom = CAtom
  { caPred :: !PredId
  , caArgs :: [Operand]
  }
  deriving (Eq, Show)

-- | A compiled rule. Variables (including each @_@) are numbered
-- @0 .. crNumVars - 1@.
data CRule = CRule
  { crHead :: !CAtom
  , crPositive :: [CAtom]
  , crNegative :: [CAtom]
  , crCompare :: [(CmpOp, Operand, Operand)]
  , crNumVars :: !Int
  }
  deriving (Eq, Show)

-- | How one column of a scanned atom is matched.
data Level
  = LConst !Int  -- ^ must equal this constant
  | LBound !Int  -- ^ must equal the variable slot (bound by an earlier step)
  | LBind !Int   -- ^ first occurrence of a variable: enumerate and store
  | LCheck !Int  -- ^ repeated occurrence within the atom: must equal the slot
  deriving (Eq, Show)

-- | Where a scan reads its tuples from.
data Source
  = Delta
    -- ^ the tuples new in the previous round, columns in atom order
  | Full !PredId [Int]
    -- ^ the whole relation through the index for this column permutation
    -- (bound columns first); the identity permutation is the relation itself
  deriving (Eq, Show)

-- | One step of a join.
data Step
  = SScan !Source [Level]
  | SNot !PredId [Operand]
  | SCmp !CmpOp !Operand !Operand
  deriving (Eq, Show)

-- | A join plan for one rule (or one delta variant of it).
data Plan = Plan
  { planHead :: !PredId
  , planHeadArgs :: [Operand]
  , planNumVars :: !Int
  , planSteps :: [Step]
  }
  deriving (Eq, Show)

data Filter = FNot CAtom | FCmp CmpOp Operand Operand

filterVars :: Filter -> [Int]
filterVars (FNot a) = [v | OVar v <- caArgs a]
filterVars (FCmp _ l r) = [v | OVar v <- [l, r]]

-- | Is this permutation @[0 .. n-1]@?
isIdentityPerm :: [Int] -> Bool
isIdentityPerm p = and (zipWith (==) p [0 ..])

-- | Plan a rule. @Just i@ reads the @i@-th positive atom from the delta.
planRule :: CRule -> Maybe Int -> Plan
planRule r mdelta = Plan (caPred (crHead r)) (caArgs (crHead r)) (crNumVars r) steps
  where
    filters = map FNot (crNegative r) ++ [FCmp o l rr | (o, l, rr) <- crCompare r]
    steps = build IS.empty filters (zip [0 :: Int ..] (crPositive r)) mdelta

    build bound pending atoms firstDelta =
      map toStep ready ++ next
      where
        (ready, pending') = partition (all (`IS.member` bound) . filterVars) pending
        next = case atoms of
          [] -> []
          _ ->
            let (i, a) = case firstDelta of
                  Just d -> byIndex d atoms
                  Nothing -> pick bound atoms
                rest = [x | x@(j, _) <- atoms, j /= i]
                (step, bound') = scanStep bound (i, a) (firstDelta /= Nothing)
             in step : build bound' pending' rest Nothing

    toStep (FNot a) = SNot (caPred a) (caArgs a)
    toStep (FCmp o l rr) = SCmp o l rr

byIndex :: Int -> [(Int, CAtom)] -> (Int, CAtom)
byIndex d atoms = case [x | x@(j, _) <- atoms, j == d] of
  x : _ -> x
  [] -> error "planRule: no such delta atom"

-- | The atom with most bound arguments; the earliest on ties.
pick :: IS.IntSet -> [(Int, CAtom)] -> (Int, CAtom)
pick bound = foldl1 (\best x -> if score x > score best then x else best)
  where
    score (_, a) = length [() | o <- caArgs a, isBound o]
    isBound (OConst _) = True
    isBound (OVar v) = IS.member v bound

-- | Build the scan step for an atom, and the bound set after it.
scanStep :: IS.IntSet -> (Int, CAtom) -> Bool -> (Step, IS.IntSet)
scanStep bound (_, CAtom p args) isDelta = (SScan src levels, bound')
  where
    classified = classify IS.empty args
    classify _ [] = []
    classify seen (o : os) = case o of
      OConst c -> (True, LConst c) : classify seen os
      OVar v
        | IS.member v bound -> (True, LBound v) : classify seen os
        | IS.member v seen -> (False, LCheck v) : classify seen os
        | otherwise -> (False, LBind v) : classify (IS.insert v seen) os
    indexed = zip [0 :: Int ..] classified
    (boundCols, freeCols) = partition (fst . snd) indexed
    perm = map fst (boundCols ++ freeCols)
    (src, levels)
      | isDelta = (Delta, map snd classified)
      | otherwise = (Full p perm, map (snd . snd) (boundCols ++ freeCols))
    bound' = IS.union bound (IS.fromList [v | OVar v <- args])

-- | The non-identity index permutations a plan needs, per predicate.
planIndexes :: Plan -> [(PredId, [Int])]
planIndexes pl = [(p, perm) | SScan (Full p perm) _ <- planSteps pl, not (isIdentityPerm perm)]

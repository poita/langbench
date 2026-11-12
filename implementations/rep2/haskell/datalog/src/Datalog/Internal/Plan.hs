-- |
-- Module      : Datalog.Internal.Plan
-- Description : Interned rules and join plans.
--
-- Rules are first interned (constants and predicates become dense
-- integers, variables become slot numbers). A rule is then compiled into
-- a 'Plan': an indexed nested-loop join over its positive atoms, with the
-- negated atoms and comparisons attached to the earliest step at which all
-- their variables are bound.
module Datalog.Internal.Plan
  ( ITerm (..)
  , IAtom (..)
  , ILit (..)
  , IRule (..)
  , Source (..)
  , Kind (..)
  , Filter (..)
  , Step (..)
  , Plan (..)
  , internRule
  , planRule
  ) where

import Data.List (mapAccumL)
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M

import Datalog.Syntax

data ITerm = IConst !Int | IVar !Int
  deriving (Eq, Show)

data IAtom = IAtom !Int [ITerm]
  deriving (Eq, Show)

data ILit = IPos IAtom | INeg IAtom | ICmp CmpOp ITerm ITerm
  deriving (Eq, Show)

-- | An interned rule; @irVars@ is the number of variable slots.
data IRule = IRule
  { irHead :: IAtom
  , irBody :: [ILit]
  , irVars :: !Int
  } deriving (Show)

-- | Intern a rule given the constant and predicate tables. Named
-- variables get slots in order of first occurrence; every @_@ gets a
-- fresh slot of its own.
internRule :: M.Map Const Int -> M.Map Predicate Int -> Rule -> IRule
internRule cm pm (Rule h body) = IRule h' body' nv
  where
    named = M.fromList (zip (dedupe vars) [0 ..])
    vars = concatMap termVars (atomArgs h) ++ concatMap litVars body
    termVars (TVar v) = [v]
    termVars _ = []
    litVars (Pos a) = concatMap termVars (atomArgs a)
    litVars (Neg a) = concatMap termVars (atomArgs a)
    litVars (Cmp _ x y) = termVars x ++ termVars y
    dedupe = go []
      where
        go _ [] = []
        go seen (x : xs) | x `elem` seen = go seen xs
                         | otherwise = x : go (x : seen) xs
    term n t = case t of
      TConst c -> (n, IConst (cm M.! c))
      TVar v -> (n, IVar (named M.! v))
      TAnon -> (n + 1, IVar n)
    atom n (Atom nm as) =
      let (n', ts) = mapAccumL term n as
      in (n', IAtom (pm M.! Predicate nm (length as)) ts)
    lit n l = case l of
      Pos a -> let (n', a') = atom n a in (n', IPos a')
      Neg a -> let (n', a') = atom n a in (n', INeg a')
      Cmp op x y ->
        let (n1, x') = term n x
            (n2, y') = term n1 y
        in (n2, ICmp op x' y')
    (n0, h') = atom (M.size named) h
    (nv, body') = mapAccumL lit n0 body

-- | Where a value comes from at run time.
data Source = SConst !Int | SSlot !Int
  deriving (Eq, Show)

-- | Which rows of a relation an atom ranges over, in a semi-naive round
-- (@lo@ is the start of the previous round's delta):
data Kind
  = KFull   -- ^ all rows
  | KOld    -- ^ rows below @lo@ (before the delta)
  | KDelta  -- ^ rows from @lo@ on (the delta)
  deriving (Eq, Show)

-- | A test applied once its variables are bound.
data Filter
  = FNeg !Int [Source]             -- ^ tuple must not be in the predicate
  | FCmp CmpOp Source Source
  deriving (Eq, Show)

-- | One positive atom of the join.
data Step = Step
  { stPred    :: !Int
  , stKind    :: !Kind
  , stKey     :: [(Int, Source)]  -- ^ columns fixed by constants / bound variables
  , stEq      :: [(Int, Int)]     -- ^ columns that must be equal (repeated variable)
  , stBind    :: [(Int, Int)]     -- ^ (column, slot) newly bound by this atom
  , stFilters :: [Filter]
  } deriving (Show)

data Plan = Plan
  { plPre   :: [Filter]           -- ^ variable-free filters, tested first
  , plSteps :: [Step]
  , plHead  :: (Int, [Source])
  , plSlots :: !Int
  } deriving (Show)

src :: ITerm -> Source
src (IConst c) = SConst c
src (IVar v) = SSlot v

filterVars :: Filter -> [Int]
filterVars (FNeg _ ss) = [v | SSlot v <- ss]
filterVars (FCmp _ a b) = [v | SSlot v <- [a, b]]

-- | Compile a rule. @isRec p@ says whether predicate @p@ belongs to the
-- component being evaluated; @delta@ is the body position of the literal
-- that reads the delta (or 'Nothing' for the initial full round).
--
-- Atoms of the component before the delta read only old rows, those after
-- it read all rows, so each combination containing a delta row is
-- produced exactly once. The join order is: the delta atom first, then
-- repeatedly the atom with most bound arguments, ties in body order.
planRule :: (Int -> Bool) -> IRule -> Maybe Int -> Plan
planRule isRec (IRule (IAtom hp hts) body nslots) delta =
  Plan pre (build IS.empty atoms0 pending0) (hp, map src hts) nslots
  where
    atoms0 = [(j, a) | (j, IPos a) <- zip [0 :: Int ..] body]
    allFilters =
      [ FNeg p (map src ts) | INeg (IAtom p ts) <- body ]
        ++ [ FCmp op (src x) (src y) | ICmp op x y <- body ]
    (pre, pending0) = (filter (null . filterVars) allFilters, filter (not . null . filterVars) allFilters)

    kindOf j p
      | not (isRec p) = KFull
      | otherwise = case delta of
          Nothing -> KFull
          Just d -> case compare j d of
            LT -> KOld
            EQ -> KDelta
            GT -> KFull

    boundCount bound (IAtom _ ts) = length [() | t <- ts, isBound t]
      where isBound (IConst _) = True
            isBound (IVar v) = v `IS.member` bound

    -- The delta atom goes first; afterwards the atom with the most bound
    -- arguments wins, the earliest in body order among equals.
    pick _ [] = Nothing
    pick bound as = Just (best, filter ((/= fst best) . fst) as)
      where
        forced = delta >>= \d -> (,) d <$> lookup d as
        best = case forced of
          Just f | IS.null bound -> f
          _ -> foldl1 (\x y -> if boundCount bound (snd y) > boundCount bound (snd x) then y else x) as

    build _ [] _ = []   -- safe rules leave no filter pending here
    build bound as pend = case pick bound as of
      Nothing -> []
      Just ((j, IAtom p ts), rest) ->
        let (key, eqs, binds, _) = foldl classify ([], [], [], M.empty) (zip [0 ..] ts)
            classify (k, e, b, seen) (c, t) = case t of
              IConst v -> ((c, SConst v) : k, e, b, seen)
              IVar v
                | v `IS.member` bound -> ((c, SSlot v) : k, e, b, seen)
                | Just c0 <- M.lookup v seen -> (k, (c0, c) : e, b, seen)
                | otherwise -> (k, e, (c, v) : b, M.insert v c seen)
            bound' = IS.union bound (IS.fromList [v | (_, v) <- binds])
            ready f = all (`IS.member` bound') (filterVars f)
            (now, later) = (filter ready pend, filter (not . ready) pend)
        in Step p (kindOf j p) (reverse key) (reverse eqs) (reverse binds) now
             : build bound' rest later

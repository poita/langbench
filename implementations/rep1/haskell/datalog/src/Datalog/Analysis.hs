-- |
-- Module      : Datalog.Analysis
-- Description : Safety and stratification checks.
--
-- A program is accepted only if every rule is /safe/ and the predicate
-- dependency graph has no cycle through a negative edge. Both checks cover
-- the whole program, before any evaluation.
module Datalog.Analysis
  ( Error (..)
  , checkSafety
  , isSafe
  , Component (..)
  , stratify
  ) where

import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Datalog.Syntax

-- | Why a program was rejected.
data Error
  = UnsafeRule Rule
    -- ^ a variable of the head, of a negated atom or of a comparison occurs
    -- in no positive body atom
  | NotStratifiable PredKey
    -- ^ the predicate lies on a dependency cycle that contains a negative edge
  deriving (Eq, Show)

-- | A strongly connected component of the predicate dependency graph.
data Component = Component
  { compPreds :: [PredKey]
  , compRecursive :: Bool
    -- ^ the component contains a cycle (including a self-loop)
  }
  deriving (Eq, Show)

-- | Is the rule safe? Every variable occurring in the head, in a negated atom
-- or in a comparison must occur in a positive body atom. Each @_@ is a fresh
-- variable, so it makes the rule unsafe anywhere but in a positive atom.
isSafe :: Rule -> Bool
isSafe (Rule h body) = all (`S.member` bound) needed && not anyAnon
  where
    bound = S.fromList [v | Pos a <- body, TVar v <- atomArgs a]
    constrained = atomArgs h ++ concat [atomArgs a | Neg a <- body]
                  ++ concat [[l, r] | Cmp _ l r <- body]
    needed = [v | TVar v <- constrained]
    anyAnon = any (== TAnon) constrained

-- | Check every rule for safety; reports the first unsafe rule.
checkSafety :: [Rule] -> Either Error ()
checkSafety rs = case filter (not . isSafe) rs of
  [] -> Right ()
  r : _ -> Left (UnsafeRule r)

-- | Compute the strongly connected components of the dependency graph in
-- dependency order (a component comes after every component it depends on),
-- or fail when a negative edge lies inside a component.
stratify :: [Rule] -> Either Error [Component]
stratify rules =
  case [k | (h, k) <- negEdges, M.lookup h compOf == M.lookup k compOf] of
    k : _ -> Left (NotStratifiable k)
    [] -> Right comps
  where
    deps :: M.Map PredKey (S.Set PredKey)
    deps = M.fromListWith S.union
      ([(atomKey (ruleHead r), S.fromList (bodyKeys r)) | r <- rules]
       ++ [(k, S.empty) | r <- rules, k <- bodyKeys r])
    bodyKeys r = [atomKey a | l <- ruleBody r, Just a <- [litAtom l]]
    litAtom (Pos a) = Just a
    litAtom (Neg a) = Just a
    litAtom _ = Nothing
    negEdges = [(atomKey (ruleHead r), atomKey a) | r <- rules, Neg a <- ruleBody r]

    sccs = stronglyConnComp [(k, k, S.toList ds) | (k, ds) <- M.toList deps]
    comps = map toComp sccs
    toComp (AcyclicSCC k) = Component [k] False
    toComp scc = Component (flatten scc) True
    flatten (AcyclicSCC k) = [k]
    flatten (CyclicSCC ks) = ks
    compOf :: M.Map PredKey Int
    compOf = M.fromList [(k, i) | (i, c) <- zip [0 :: Int ..] comps, k <- compPreds c]


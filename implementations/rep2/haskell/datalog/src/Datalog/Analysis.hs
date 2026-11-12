-- |
-- Module      : Datalog.Analysis
-- Description : Safety and stratification checks.
module Datalog.Analysis
  ( AnalysisError (..)
  , unsafeRules
  , isSafe
  , stratify
  , check
  ) where

import Data.Graph (flattenSCC, stronglyConnComp)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Datalog.Syntax

-- | Why a program was rejected.
data AnalysisError
  = UnsafeRule Rule          -- ^ a rule with an unbound variable
  | NotStratifiable Predicate -- ^ a predicate on a cycle through negation
  deriving (Eq, Show)

-- | A rule is safe when every variable in its head, in a negated atom or
-- in a comparison also occurs in a positive body atom. An anonymous
-- variable in any of those places is therefore unsafe.
isSafe :: Rule -> Bool
isSafe (Rule h body) = all ok restricted
  where
    positive = S.fromList [v | Pos a <- body, TVar v <- atomArgs a]
    restricted =
      atomArgs h
        ++ concat [atomArgs a | Neg a <- body]
        ++ concat [[x, y] | Cmp _ x y <- body]
    ok (TVar v) = v `S.member` positive
    ok TAnon = False
    ok (TConst _) = True

-- | All unsafe rules, in program order.
unsafeRules :: Program -> [Rule]
unsafeRules = filter (not . isSafe) . progRules

-- | Dependency edges @(head, body predicate, negative?)@.
edges :: Program -> [(Predicate, Predicate, Bool)]
edges p =
  [ (atomPredicate h, atomPredicate a, neg)
  | Rule h body <- progRules p
  , lit <- body
  , (a, neg) <- case lit of
      Pos a -> [(a, False)]
      Neg a -> [(a, True)]
      Cmp {} -> []
  ]

-- | Strongly connected components of the predicate dependency graph, in
-- evaluation order (every component after the components it depends on),
-- or the predicate of a negative edge lying inside a component.
--
-- Every predicate mentioned in a rule appears in exactly one component.
stratify :: Program -> Either AnalysisError [[Predicate]]
stratify p =
  case [h | (h, b, True) <- es, M.lookup h comp == M.lookup b comp] of
    h : _ -> Left (NotStratifiable h)
    [] -> Right (map flattenSCC sccs)
  where
    es = edges p
    preds = nub (concat [[h, b] | (h, b, _) <- es] ++ map (atomPredicate . ruleHead) (progRules p))
    deps = M.fromListWith (++) [(h, [b]) | (h, b, _) <- es]
    sccs = stronglyConnComp [(q, q, M.findWithDefault [] q deps) | q <- preds]
    comp = M.fromList [(q, i) | (i, c) <- zip [0 :: Int ..] sccs, q <- flattenSCC c]

-- | Run both checks (safety first), returning the evaluation order.
check :: Program -> Either AnalysisError [[Predicate]]
check p = case unsafeRules p of
  r : _ -> Left (UnsafeRule r)
  [] -> stratify p

{-# LANGUAGE OverloadedStrings #-}

-- | Predicates, scan options and plan selection (SPEC §6.5, §17).
module Tessera.Query
  ( CmpOp (..)
  , Pred (..)
  , ScanOptions (..)
  , defaultScanOptions
  , Plan (..)
  , planText
  , evalPred
  , flattenAnd
  , choosePlan
  ) where

import qualified Data.ByteString as BS
import Data.List (minimumBy)
import Data.Maybe (isJust, isNothing)
import Data.Ord (comparing)
import Tessera.Path (Path, pathText, resolve)
import Tessera.Value (Value (..))

-- | Comparison operators of the predicate language.
data CmpOp = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe
  deriving (Eq, Show)

-- | A predicate tree.  @and@ and @or@ are binary and left-associative.
data Pred
  = PAnd Pred Pred
  | POr Pred Pred
  | PNot Pred
  | PExists Path
  | PMissing Path
  | PCmp Path CmpOp Value
  deriving (Eq, Show)

-- | Options of the @scan@ command.
data ScanOptions = ScanOptions
  { scanFrom :: Maybe BS.ByteString
  -- ^ inclusive lower bound
  , scanTo :: Maybe BS.ByteString
  -- ^ exclusive upper bound
  , scanLimit :: Maybe Int
  , scanReverse :: Bool
  , scanKeysOnly :: Bool
  }
  deriving (Eq, Show)

-- | A scan of everything, ascending, with documents.
defaultScanOptions :: ScanOptions
defaultScanOptions = ScanOptions Nothing Nothing Nothing False False

-- | How a @find@ is evaluated.
data Plan = PlanScan | PlanIndex Path
  deriving (Eq, Show)

-- | @scan@ or @index <path>@, as printed in results.
planText :: Plan -> BS.ByteString
planText PlanScan = "scan"
planText (PlanIndex p) = "index " <> pathText p

-- | Evaluate a predicate against a document (SPEC §17.2).
evalPred :: Pred -> Value -> Bool
evalPred p doc = case p of
  PAnd a b -> evalPred a doc && evalPred b doc
  POr a b -> evalPred a doc || evalPred b doc
  PNot a -> not (evalPred a doc)
  PExists path -> isJust (resolve path doc)
  PMissing path -> isNothing (resolve path doc)
  PCmp path op v -> maybe False (\x -> compareWith op x v) (resolve path doc)

compareWith :: CmpOp -> Value -> Value -> Bool
compareWith op x v = case op of
  OpEq -> x == v
  OpNe -> x /= v
  OpLt -> ordered (== LT)
  OpLe -> ordered (/= GT)
  OpGt -> ordered (== GT)
  OpGe -> ordered (/= LT)
  where
    ordered f = maybe False f (scalarOrder x v)

-- | Ordering of two scalars of the same kind; 'Nothing' otherwise.
scalarOrder :: Value -> Value -> Maybe Ordering
scalarOrder a b = case (a, b) of
  (VNull, VNull) -> Just EQ
  (VBool x, VBool y) -> Just (compare x y)
  (VInt x, VInt y) -> Just (compare x y)
  (VString x, VString y) -> Just (compare x y)
  _ -> Nothing

-- | The leaves of a predicate once top-level @and@ nodes are flattened.
flattenAnd :: Pred -> [Pred]
flattenAnd (PAnd a b) = flattenAnd a ++ flattenAnd b
flattenAnd p = [p]

-- | Choose the comparison leaf an index plan would use (SPEC §17.3), given a
-- test for which paths have a live index.  'Nothing' means a scan plan.
choosePlan :: (Path -> Bool) -> Pred -> Maybe (Path, CmpOp, Value)
choosePlan hasIndex p = case usable of
  [] -> Nothing
  _ -> Just (minimumBy (comparing rank) usable)
  where
    usable = [(path, op, v) | PCmp path op v <- flattenAnd p, op /= OpNe, scalar v, hasIndex path]
    rank (path, op, _) = (if op == OpEq then 0 else 1 :: Int, pathText path)
    scalar v = case v of
      VList _ -> False
      VObject _ -> False
      _ -> True

-- |
-- Module      : Datalog.Model
-- Description : The computed model and query answering.
module Datalog.Model
  ( Model (..)
  , Rows (..)
  , modelTuples
  , queryModel
  ) where

import Data.Array (Array, (!))
import Data.Array.Unboxed (UArray)
import qualified Data.Array.Unboxed as U
import Data.List (sort)
import qualified Data.Map.Strict as M

import Datalog.Syntax

-- | Frozen contents of one relation: @rowsCount@ rows of @rowsArity@
-- constant ids, stored row-major.
data Rows = Rows
  { rowsArity :: !Int
  , rowsCount :: !Int
  , rowsData  :: !(UArray Int Int)
  }

-- | The perfect model. Constants are represented by their rank in the
-- total order, so id order is constant order.
data Model = Model
  { modelConsts :: Array Int Const   -- ^ id -> constant
  , modelIds    :: M.Map Const Int   -- ^ constant -> id
  , modelRels   :: M.Map Predicate Rows
  }

rowList :: Rows -> Int -> [Int]
rowList (Rows ar _ d) r = [d U.! (r * ar + c) | c <- [0 .. ar - 1]]

-- | All tuples of a predicate (name and arity), in ascending order.
-- Unknown predicates are empty.
modelTuples :: Model -> Predicate -> [[Const]]
modelTuples m p = case M.lookup p (modelRels m) of
  Nothing -> []
  Just rs -> map (map (modelConsts m !)) (sort [rowList rs r | r <- [0 .. rowsCount rs - 1]])

-- | Answer a query atom: the matching tuples in ascending order. A
-- constant occurring in the query matches only equal constants, a variable
-- occurring several times must bind consistently and @_@ matches anything.
queryModel :: Model -> Atom -> [[Const]]
queryModel m q = case M.lookup (atomPredicate q) (modelRels m) of
  Nothing -> []
  Just rs -> case mapM resolve (atomArgs q) of
    Nothing -> []
    Just pat ->
      map (map (modelConsts m !))
        . sort
        $ [t | r <- [0 .. rowsCount rs - 1], let t = rowList rs r, matches pat t]
  where
    resolve (TConst c) = Left <$> M.lookup c (modelIds m)
    resolve (TVar v) = Just (Right (Just v))
    resolve TAnon = Just (Right Nothing)

matches :: [Either Int (Maybe String)] -> [Int] -> Bool
matches = go []
  where
    go _ [] [] = True
    go env (p : ps) (x : xs) = case p of
      Left c -> c == x && go env ps xs
      Right Nothing -> go env ps xs
      Right (Just v) -> case lookup v env of
        Just y -> y == x && go env ps xs
        Nothing -> go ((v, x) : env) ps xs
    go _ _ _ = False

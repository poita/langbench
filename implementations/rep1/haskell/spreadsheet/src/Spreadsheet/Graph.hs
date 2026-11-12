-- |
-- Module      : Spreadsheet.Graph
-- Description : Tarjan's strongly-connected-components algorithm.
module Spreadsheet.Graph
  ( Component (..)
  , components
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet

-- | A strongly connected component of a directed graph.
data Component
  = Acyclic !Int
    -- ^ A single node that does not reach itself.
  | Cyclic [Int]
    -- ^ A cycle: several nodes, or one node with an edge to itself.
  deriving (Eq, Show)

data St = St
  { stCounter :: !Int
  , stIndex :: !(IntMap Int)
  , stLow :: !(IntMap Int)
  , stStack :: [Int]
  , stOnStack :: !IntSet
  , stOut :: [Component]  -- ^ emitted components, most recent first
  }

-- | @components succs roots@ runs Tarjan's algorithm from every node in
-- @roots@ (skipping those already visited), following the edges given by
-- @succs@, and returns the components of everything reached in an order
-- where each component comes /after/ every component it has edges to.
-- With edges pointing from a cell to the cells it reads, that is
-- dependencies first.
--
-- Runs in O(V + E) map operations; recursion depth is the length of the
-- longest path, which GHC's growable stack handles.
components :: (Int -> [Int]) -> [Int] -> [Component]
components succs roots = reverse (stOut final)
  where
    final = foldl' root st0 roots
    st0 = St 0 IntMap.empty IntMap.empty [] IntSet.empty []
    root st v
      | IntMap.member v (stIndex st) = st
      | otherwise = visit st v

    visit st v =
      let i = stCounter st
          st1 =
            st
              { stCounter = i + 1
              , stIndex = IntMap.insert v i (stIndex st)
              , stLow = IntMap.insert v i (stLow st)
              , stStack = v : stStack st
              , stOnStack = IntSet.insert v (stOnStack st)
              }
          ws = succs v
          st2 = foldl' (edge v) st1 ws
       in if IntMap.findWithDefault i v (stLow st2) == i
            then emit st2 v ws
            else st2

    edge v st w
      | not (IntMap.member w (stIndex st)) =
          let st' = visit st w
           in lower v (IntMap.findWithDefault 0 w (stLow st')) st'
      | IntSet.member w (stOnStack st) = lower v (IntMap.findWithDefault 0 w (stIndex st)) st
      | otherwise = st

    lower v x st = st {stLow = IntMap.adjust (min x) v (stLow st)}

    -- Pop the component rooted at v off the stack.
    emit st v ws =
      let (members, rest) = pop (stStack st) []
          pop (x : xs) acc
            | x == v = (x : acc, xs)
            | otherwise = pop xs (x : acc)
          pop [] acc = (acc, [])
          comp = case members of
            [m] | m `notElem` ws -> Acyclic m
            _ -> Cyclic members
       in st
            { stStack = rest
            , stOnStack = foldl' (flip IntSet.delete) (stOnStack st) members
            , stOut = comp : stOut st
            }

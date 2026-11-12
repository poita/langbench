-- |
-- Module      : Datalog.Trie
-- Description : Persistent sets of fixed-arity integer tuples.
--
-- A 'Trie' stores a set of tuples of a fixed arity (at least one) as nested
-- 'IntMap's with an 'IntSet' at the last level. Tuples enumerate in
-- lexicographic order. Relations and their indexes are tries: an index for a
-- given column permutation is simply a trie of the permuted tuples, so
-- looking up a bound prefix yields the sub-trie of matching tuples.
module Datalog.Trie
  ( Trie (..)
  , empty
  , null
  , member
  , insert
  , union
  , toList
  , fromList
  , size
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Prelude hiding (null)

-- | A set of equal-length tuples (arity >= 1).
data Trie
  = Leaf !IS.IntSet
  | Node !(IM.IntMap Trie)
  deriving (Eq, Show)

-- | The empty trie for tuples of the given arity.
empty :: Int -> Trie
empty 1 = Leaf IS.empty
empty _ = Node IM.empty

null :: Trie -> Bool
null (Leaf s) = IS.null s
null (Node m) = IM.null m

-- | Membership of a whole tuple.
member :: [Int] -> Trie -> Bool
member [k] (Leaf s) = IS.member k s
member (k : ks) (Node m) = maybe False (member ks) (IM.lookup k m)
member _ _ = False

single :: [Int] -> Trie
single [k] = Leaf (IS.singleton k)
single (k : ks) = Node (IM.singleton k (single ks))
single [] = error "Datalog.Trie.single: empty tuple"

-- | Insert a tuple (whose length must equal the trie's arity).
insert :: [Int] -> Trie -> Trie
insert [k] (Leaf s) = Leaf (IS.insert k s)
insert (k : ks) (Node m) = Node (IM.insertWith (\_ old -> insert ks old) k (single ks) m)
insert _ _ = error "Datalog.Trie.insert: arity mismatch"

-- | Set union.
union :: Trie -> Trie -> Trie
union (Leaf a) (Leaf b) = Leaf (IS.union a b)
union (Node a) (Node b) = Node (IM.unionWith union a b)
union _ _ = error "Datalog.Trie.union: arity mismatch"

-- | All tuples in ascending lexicographic order.
toList :: Trie -> [[Int]]
toList (Leaf s) = [[x] | x <- IS.toAscList s]
toList (Node m) = [k : r | (k, t) <- IM.toAscList m, r <- toList t]

-- | Build a trie of the given arity from tuples.
fromList :: Int -> [[Int]] -> Trie
fromList n = foldl' (flip insert) (empty n)

-- | Number of tuples.
size :: Trie -> Int
size (Leaf s) = IS.size s
size (Node m) = IM.foldl' (\a t -> a + size t) 0 m

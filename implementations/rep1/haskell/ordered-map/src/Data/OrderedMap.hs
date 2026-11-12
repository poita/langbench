-- |
-- Module      : Data.OrderedMap
-- Description : Balanced ordered map with rank/select and neighbour queries
--
-- An ordered map implemented as a hand-written AVL tree augmented with
-- subtree sizes. Every operation below is /O(log n)/ unless stated
-- otherwise, where /n/ is the number of entries.
--
-- Besides the usual dictionary operations the map supports
--
-- * /order statistics/: 'rank' (how many keys are smaller) and 'select'
--   (the k-th smallest entry), both using the cached subtree sizes;
-- * /neighbour queries/: 'lookupFloor', 'lookupCeil', 'lookupSucc',
--   'lookupPred';
-- * /range listing/: 'range' and 'rangeKeys' walk only the part of the tree
--   that can intersect @[lo, hi]@, in /O(log n + r)/ for /r/ results.
--
-- Neighbour queries compare keys; they never compute @key + 1@ or
-- @key - 1@, so they are correct at the extremes of a bounded key type
-- such as 'Int'.
--
-- The map is spine- and key/value-strict and purely functional (updates
-- return a new map sharing structure with the old one).
--
-- Typically imported qualified:
--
-- > import qualified Data.OrderedMap as OM
-- >
-- > let m = OM.fromList [(10, "a"), (20, "b"), (30, "c")]
-- > OM.lookupFloor 25 m   -- Just (20,"b")
-- > OM.rank 20 m          -- 1
-- > OM.select 2 m         -- Just (30,"c")
module Data.OrderedMap
  ( OrderedMap
    -- * Construction
  , empty
  , singleton
  , fromList
    -- * Size
  , null
  , size
    -- * Insertion and deletion
  , insert
  , insertLookup
  , delete
  , deleteLookup
    -- * Lookup
  , lookup
  , member
  , lookupMin
  , lookupMax
    -- * Neighbour queries
  , lookupFloor
  , lookupCeil
  , lookupSucc
  , lookupPred
    -- * Order statistics
  , rank
  , select
    -- * Traversal
  , toAscList
  , keys
  , range
  , rangeKeys
  , foldrRange
  ) where

import Prelude hiding (lookup, null)

import Data.List (foldl')
import Data.OrderedMap.Internal
  ( OrderedMap (..)
  , deleteLookup
  , empty
  , insertLookup
  , singleton
  , size
  )

-- | Is the map empty? /O(1)/.
null :: OrderedMap k v -> Bool
null Tip = True
null _ = False

-- | Insert an entry, replacing the value if the key is already present.
insert :: Ord k => k -> v -> OrderedMap k v -> OrderedMap k v
insert k v = snd . insertLookup k v
{-# INLINABLE insert #-}

-- | Delete a key; the map is unchanged if the key is absent.
delete :: Ord k => k -> OrderedMap k v -> OrderedMap k v
delete k = snd . deleteLookup k
{-# INLINABLE delete #-}

-- | Build a map from a list; later entries win over earlier ones with the
-- same key. /O(m log m)/ for a list of /m/ entries.
fromList :: Ord k => [(k, v)] -> OrderedMap k v
fromList = foldl' (\m (k, v) -> insert k v m) empty

-- | The value stored under a key.
lookup :: Ord k => k -> OrderedMap k v -> Maybe v
lookup !k = go
  where
    go Tip = Nothing
    go (Bin _ _ kx v l r) = case compare k kx of
      LT -> go l
      GT -> go r
      EQ -> Just v
{-# INLINABLE lookup #-}

-- | Is the key present?
member :: Ord k => k -> OrderedMap k v -> Bool
member k m = case lookup k m of
  Nothing -> False
  Just _ -> True
{-# INLINABLE member #-}

-- | The entry with the smallest key.
lookupMin :: OrderedMap k v -> Maybe (k, v)
lookupMin Tip = Nothing
lookupMin (Bin _ _ k v Tip _) = Just (k, v)
lookupMin (Bin _ _ _ _ l _) = lookupMin l

-- | The entry with the largest key.
lookupMax :: OrderedMap k v -> Maybe (k, v)
lookupMax Tip = Nothing
lookupMax (Bin _ _ k v _ Tip) = Just (k, v)
lookupMax (Bin _ _ _ _ _ r) = lookupMax r

-- | /Floor/: the entry with the largest key @<= k@.
lookupFloor :: Ord k => k -> OrderedMap k v -> Maybe (k, v)
lookupFloor !k = go Nothing
  where
    go best Tip = best
    go best (Bin _ _ kx v l r) = case compare k kx of
      LT -> go best l
      EQ -> Just (kx, v)
      GT -> go (Just (kx, v)) r
{-# INLINABLE lookupFloor #-}

-- | /Ceiling/: the entry with the smallest key @>= k@.
lookupCeil :: Ord k => k -> OrderedMap k v -> Maybe (k, v)
lookupCeil !k = go Nothing
  where
    go best Tip = best
    go best (Bin _ _ kx v l r) = case compare k kx of
      GT -> go best r
      EQ -> Just (kx, v)
      LT -> go (Just (kx, v)) l
{-# INLINABLE lookupCeil #-}

-- | /Successor/: the entry with the smallest key strictly @> k@.
lookupSucc :: Ord k => k -> OrderedMap k v -> Maybe (k, v)
lookupSucc !k = go Nothing
  where
    go best Tip = best
    go best (Bin _ _ kx v l r)
      | k < kx = go (Just (kx, v)) l
      | otherwise = go best r
{-# INLINABLE lookupSucc #-}

-- | /Predecessor/: the entry with the largest key strictly @< k@.
lookupPred :: Ord k => k -> OrderedMap k v -> Maybe (k, v)
lookupPred !k = go Nothing
  where
    go best Tip = best
    go best (Bin _ _ kx v l r)
      | k > kx = go (Just (kx, v)) r
      | otherwise = go best l
{-# INLINABLE lookupPred #-}

-- | Number of keys strictly less than the argument (which need not be
-- present). Uses the cached subtree sizes.
rank :: Ord k => k -> OrderedMap k v -> Int
rank !k = go 0
  where
    go !acc Tip = acc
    go !acc (Bin _ _ kx _ l r) = case compare k kx of
      LT -> go acc l
      GT -> go (acc + size l + 1) r
      EQ -> acc + size l
{-# INLINABLE rank #-}

-- | The entry with the given 0-based rank in ascending key order, or
-- 'Nothing' if the index is negative or @>= 'size'@.
select :: Int -> OrderedMap k v -> Maybe (k, v)
select i t
  | i < 0 || i >= size t = Nothing
  | otherwise = go i t
  where
    go _ Tip = Nothing
    go n (Bin _ _ k v l r)
      | n < sl = go n l
      | n == sl = Just (k, v)
      | otherwise = go (n - sl - 1) r
      where sl = size l

-- | All entries in ascending key order. /O(n)/, lazy.
toAscList :: OrderedMap k v -> [(k, v)]
toAscList = go []
  where
    go z Tip = z
    go z (Bin _ _ k v l r) = go ((k, v) : go z r) l

-- | All keys in ascending order. /O(n)/, lazy.
keys :: OrderedMap k v -> [k]
keys = map fst . toAscList

-- | Right fold over the entries whose keys lie in the inclusive interval
-- @[lo, hi]@, in ascending order. Subtrees entirely outside the interval are
-- never visited, so the cost is /O(log n + r)/ for /r/ visited entries. If
-- @lo > hi@ the result is the initial accumulator.
foldrRange :: Ord k => k -> k -> (k -> v -> a -> a) -> a -> OrderedMap k v -> a
foldrRange !lo !hi f = flip go
  where
    go Tip acc = acc
    go (Bin _ _ k v l r) acc
      | k < lo = go r acc
      | k > hi = go l acc
      | otherwise = go l (f k v (go r acc))
{-# INLINABLE foldrRange #-}

-- | Entries with keys in @[lo, hi]@ in ascending order (lazy).
-- Empty if @lo > hi@.
range :: Ord k => k -> k -> OrderedMap k v -> [(k, v)]
range lo hi m = foldrRange lo hi (\k v acc -> (k, v) : acc) [] m
{-# INLINABLE range #-}

-- | Keys in @[lo, hi]@ in ascending order (lazy).
rangeKeys :: Ord k => k -> k -> OrderedMap k v -> [k]
rangeKeys lo hi m = foldrRange lo hi (\k _ acc -> k : acc) [] m
{-# INLINABLE rangeKeys #-}

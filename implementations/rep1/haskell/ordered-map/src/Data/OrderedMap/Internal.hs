{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Data.OrderedMap.Internal
-- Description : The AVL tree behind "Data.OrderedMap"
--
-- This module holds the data representation and the balancing machinery.
-- It is exposed for testing and for advanced use; its API is not covered by
-- the package's stability promise. Prefer "Data.OrderedMap".
--
-- = Representation
--
-- A tree is either 'Tip' or a 'Bin' node carrying
--
-- * the number of entries in the subtree (for O(log n) rank and select),
-- * the height of the subtree (for AVL balancing),
-- * a key, a value and the two children.
--
-- /Invariants/ (checked by 'valid'):
--
-- 1. binary-search order: every key in the left subtree is smaller than the
--    node's key, every key in the right subtree is larger;
-- 2. cached sizes and heights are correct;
-- 3. AVL balance: the heights of the two children differ by at most one.
module Data.OrderedMap.Internal
  ( OrderedMap (..)
    -- * Construction
  , empty
  , singleton
    -- * Measurement
  , size
  , height
    -- * Updating
  , insertLookup
  , deleteLookup
    -- * Balancing helpers
  , bin
  , balance
  , minViewSure
  , maxViewSure
    -- * Invariant checking
  , valid
  ) where

-- | An ordered map from keys @k@ to values @v@, implemented as an AVL tree
-- with subtree sizes. The key and value fields are strict (evaluated to WHNF
-- on insertion).
data OrderedMap k v
  = Tip
  | Bin
      {-# UNPACK #-} !Int  -- size of this subtree
      {-# UNPACK #-} !Int  -- height of this subtree
      !k
      !v
      !(OrderedMap k v)    -- left (smaller keys)
      !(OrderedMap k v)    -- right (larger keys)

-- | The empty map. /O(1)/.
empty :: OrderedMap k v
empty = Tip

-- | A map with a single entry. /O(1)/.
singleton :: k -> v -> OrderedMap k v
singleton k v = Bin 1 1 k v Tip Tip

-- | Number of entries. /O(1)/.
size :: OrderedMap k v -> Int
size Tip = 0
size (Bin s _ _ _ _ _) = s

-- | Height of the tree (0 for the empty map). /O(1)/.
height :: OrderedMap k v -> Int
height Tip = 0
height (Bin _ h _ _ _ _) = h

-- | Smart constructor: builds a node, computing size and height.
-- Does not rebalance.
bin :: k -> v -> OrderedMap k v -> OrderedMap k v -> OrderedMap k v
bin k v l r = Bin (size l + size r + 1) (max (height l) (height r) + 1) k v l r
{-# INLINE bin #-}

-- | Rebuild a node whose subtrees are each valid AVL trees but whose heights
-- may differ by up to two (as happens after one insertion or deletion below
-- it). Performs at most a single or double rotation. /O(1)/.
balance :: k -> v -> OrderedMap k v -> OrderedMap k v -> OrderedMap k v
balance k v l r
  | hl > hr + 1 = case l of
      Bin _ _ lk lv ll lr
        | height ll >= height lr -> bin lk lv ll (bin k v lr r)           -- right rotation
        | Bin _ _ mk mv ml mr <- lr ->                                    -- left-right
            bin mk mv (bin lk lv ll ml) (bin k v mr r)
      _ -> bin k v l r  -- unreachable: hl > hr + 1 >= 1 implies l is a Bin
  | hr > hl + 1 = case r of
      Bin _ _ rk rv rl rr
        | height rr >= height rl -> bin rk rv (bin k v l rl) rr           -- left rotation
        | Bin _ _ mk mv ml mr <- rl ->                                    -- right-left
            bin mk mv (bin k v l ml) (bin rk rv mr rr)
      _ -> bin k v l r
  | otherwise = bin k v l r
  where
    hl = height l
    hr = height r

-- | Insert, replacing any existing value, and report the old value if the key
-- was present. /O(log n)/.
insertLookup :: Ord k => k -> v -> OrderedMap k v -> (Maybe v, OrderedMap k v)
insertLookup !kx vx = go
  where
    go Tip = (Nothing, singleton kx vx)
    go (Bin s h k v l r) = case compare kx k of
      LT -> let (old, l') = go l in (old, balance k v l' r)
      GT -> let (old, r') = go r in (old, balance k v l r')
      EQ -> (Just v, Bin s h kx vx l r)
{-# INLINABLE insertLookup #-}

-- | Delete a key, reporting the removed value if it was present.
-- When the key is absent the original tree is returned unchanged.
-- /O(log n)/.
deleteLookup :: Ord k => k -> OrderedMap k v -> (Maybe v, OrderedMap k v)
deleteLookup !kx = go
  where
    go Tip = (Nothing, Tip)
    go t@(Bin _ _ k v l r) = case compare kx k of
      LT -> case go l of
              (Nothing, _) -> (Nothing, t)
              (old, l')    -> (old, balance k v l' r)
      GT -> case go r of
              (Nothing, _) -> (Nothing, t)
              (old, r')    -> (old, balance k v l r')
      EQ -> (Just v, glue l r)
{-# INLINABLE deleteLookup #-}

-- | Join two trees whose key ranges are ordered (all of @l@ below all of @r@)
-- and whose heights differ by at most one, by pulling a replacement root
-- from the taller side.
glue :: OrderedMap k v -> OrderedMap k v -> OrderedMap k v
glue Tip r = r
glue l Tip = l
glue l r
  | height l > height r = case maxViewSure l of (k, v, l') -> balance k v l' r
  | otherwise           = case minViewSure r of (k, v, r') -> balance k v l r'

-- | Remove the minimum entry of a non-empty tree. Returns key, value and the
-- remainder; on 'Tip' (a precondition violation) it returns an error.
minViewSure :: OrderedMap k v -> (k, v, OrderedMap k v)
minViewSure Tip = error "Data.OrderedMap.Internal.minViewSure: empty map"
minViewSure (Bin _ _ k v Tip r) = (k, v, r)
minViewSure (Bin _ _ k v l r) = case minViewSure l of
  (km, vm, l') -> (km, vm, balance k v l' r)

-- | Remove the maximum entry of a non-empty tree.
maxViewSure :: OrderedMap k v -> (k, v, OrderedMap k v)
maxViewSure Tip = error "Data.OrderedMap.Internal.maxViewSure: empty map"
maxViewSure (Bin _ _ k v l Tip) = (k, v, l)
maxViewSure (Bin _ _ k v l r) = case maxViewSure r of
  (km, vm, r') -> (km, vm, balance k v l r')

-- | Check every structural invariant (order, sizes, heights, AVL balance).
-- /O(n)/. Intended for tests.
valid :: Ord k => OrderedMap k v -> Bool
valid t = ordered t && sound t
  where
    ordered = increasing . keysOf
    keysOf m = foldr' m []
      where foldr' Tip acc = acc
            foldr' (Bin _ _ k _ l r) acc = foldr' l (k : foldr' r acc)
    increasing (a : rest@(b : _)) = a < b && increasing rest
    increasing _ = True
    sound Tip = True
    sound (Bin s h _ _ l r) =
      s == size l + size r + 1
        && h == max (height l) (height r) + 1
        && abs (height l - height r) <= 1
        && sound l && sound r

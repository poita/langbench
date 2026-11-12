{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Datalog.Internal.Relation
-- Description : Mutable tuple sets with incrementally maintained hash indexes.
--
-- A relation stores its rows in one flat unboxed array (row @r@, column
-- @c@ at @r * arity + c@). Rows are only ever appended, so a row's number
-- is stable and "the rows added in round k" is a contiguous range.
--
-- An index is a chained hash table over a subset of the columns: a bucket
-- array holding the newest row of each chain and a per-row @next@ array.
-- Rows are pushed at the head, so every chain is in strictly descending
-- row order. Each index is updated once per inserted row (the bucket array
-- is doubled, with a relink, when it fills), so it costs O(rows) overall.
--
-- New tuples produced during a round go to a per-relation buffer and are
-- merged ('flushBuffer') between rounds; relations are therefore never
-- modified while a join is reading them.
module Datalog.Internal.Relation
  ( Arr
  , Relation
  , Index
  , relArity
  , relRows
  , newRelation
  , relSize
  , addIndex
  , memberRow
  , pushBuffer
  , flushBuffer
  , hashSeq
  , chainStart
  , chainNext
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST)
import Data.Array.Base (getNumElements, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import Data.Bits (unsafeShiftR, xor, (.&.))
import Data.STRef

-- | Mutable unboxed @Int@ array.
type Arr s = STUArray s Int Int

newArr :: Int -> Int -> ST s (Arr s)
newArr n = newArray (0, n - 1)

-- | Grow an array to at least the given capacity, preserving contents.
ensureCap :: STRef s (Arr s) -> Int -> Int -> ST s (Arr s)
ensureCap ref need fill = do
  arr <- readSTRef ref
  cap <- getNumElements arr
  if need <= cap
    then pure arr
    else do
      let cap' = max need (2 * cap)
      arr' <- newArr cap' fill
      let copy !i | i >= cap = pure ()
                  | otherwise = unsafeRead arr i >>= unsafeWrite arr' i >> copy (i + 1)
      copy 0
      writeSTRef ref arr'
      pure arr'

data Index s = Index
  { ixCols  :: ![Int]
  , ixHeads :: !(STRef s (Arr s))
  , ixNext  :: !(STRef s (Arr s))
  , ixMeta  :: !(Arr s)  -- ^ 0: bucket mask
  }

data Relation s = Relation
  { relArity   :: !Int
  , relRows    :: !(STRef s (Arr s))
  , relMeta    :: !(Arr s)  -- ^ 0: row count, 1: buffered row count
  , relBuf     :: !(STRef s (Arr s))
  , relIndexes :: !(STRef s [Index s])
  , relFull    :: !(Index s)
  }

newIndex :: [Int] -> ST s (Index s)
newIndex cols = do
  heads <- newArr 16 (-1) >>= newSTRef
  next <- newArr 16 (-1) >>= newSTRef
  meta <- newArr 1 15
  pure (Index cols heads next meta)

-- | An empty relation of the given arity (>= 1).
newRelation :: Int -> ST s (Relation s)
newRelation ar = do
  rows <- newArr (16 * ar) 0 >>= newSTRef
  meta <- newArr 2 0
  buf <- newArr (16 * ar) 0 >>= newSTRef
  full <- newIndex [0 .. ar - 1]
  ixs <- newSTRef [full]
  pure (Relation ar rows meta buf ixs full)

-- | Number of rows currently in the relation (excluding the buffer).
relSize :: Relation s -> ST s Int
relSize r = unsafeRead (relMeta r) 0

mixK :: Int
mixK = fromIntegral (0x9E3779B97F4A7C15 :: Word)

hashStep :: Int -> Int -> Int
hashStep h x = (h `xor` x) * mixK

hashFinish :: Int -> Int
hashFinish h = h `xor` (h `unsafeShiftR` 32)

hashSeed :: Int
hashSeed = 17

-- | Hash of @n@ consecutive values of an array starting at an offset.
hashSeq :: Arr s -> Int -> Int -> ST s Int
hashSeq arr off n = go hashSeed 0
  where
    go !h !i
      | i >= n = pure (hashFinish h)
      | otherwise = unsafeRead arr (off + i) >>= \x -> go (hashStep h x) (i + 1)

-- | Hash of the indexed columns of a stored row (same value as 'hashSeq'
-- on the extracted key).
hashRow :: Arr s -> Int -> [Int] -> ST s Int
hashRow arr base = go hashSeed
  where
    go !h [] = pure (hashFinish h)
    go !h (c : cs) = unsafeRead arr (base + c) >>= \x -> go (hashStep h x) cs

linkRow :: Arr s -> Arr s -> Arr s -> Int -> Index s -> Int -> Int -> ST s ()
linkRow dat heads next ar ix mask r = do
  h <- hashRow dat (r * ar) (ixCols ix)
  let b = h .&. mask
  hd <- unsafeRead heads b
  unsafeWrite next r hd
  unsafeWrite heads b r

-- | Insert row @r@ (already stored in @dat@) into an index.
indexInsert :: Arr s -> Int -> Index s -> Int -> ST s ()
indexInsert dat ar ix r = do
  next <- ensureCap (ixNext ix) (r + 1) (-1)
  mask <- unsafeRead (ixMeta ix) 0
  if r > mask
    then do
      let mask' = 2 * (mask + 1) - 1
      heads' <- newArr (mask' + 1) (-1)
      forM_ [0 .. r] $ \i -> linkRow dat heads' next ar ix mask' i
      writeSTRef (ixHeads ix) heads'
      unsafeWrite (ixMeta ix) 0 mask'
    else do
      heads <- readSTRef (ixHeads ix)
      linkRow dat heads next ar ix mask r

-- | Index over the given columns (looked up or created and backfilled).
addIndex :: Relation s -> [Int] -> ST s (Index s)
addIndex rel cols = do
  ixs <- readSTRef (relIndexes rel)
  case filter ((== cols) . ixCols) ixs of
    ix : _ -> pure ix
    [] -> do
      ix <- newIndex cols
      n <- relSize rel
      dat <- readSTRef (relRows rel)
      forM_ [0 .. n - 1] $ indexInsert dat (relArity rel) ix
      writeSTRef (relIndexes rel) (ix : ixs)
      pure ix

-- | First row of the chain for a key hash, or @-1@.
chainStart :: Index s -> Int -> ST s Int
chainStart ix h = do
  mask <- unsafeRead (ixMeta ix) 0
  heads <- readSTRef (ixHeads ix)
  unsafeRead heads (h .&. mask)

-- | Next (older) row in a chain, or @-1@.
chainNext :: Index s -> Int -> ST s Int
chainNext ix r = do
  next <- readSTRef (ixNext ix)
  unsafeRead next r

-- | Is the tuple stored at an offset of the array present in the relation?
memberRow :: Relation s -> Arr s -> Int -> ST s Bool
memberRow rel tup off = do
  let ar = relArity rel
  h <- hashSeq tup off ar
  dat <- readSTRef (relRows rel)
  let walk !r
        | r < 0 = pure False
        | otherwise = do
            eq <- same dat (r * ar) 0
            if eq then pure True else chainNext (relFull rel) r >>= walk
      same d !base !i
        | i >= ar = pure True
        | otherwise = do
            a <- unsafeRead d (base + i)
            b <- unsafeRead tup (off + i)
            if a == b then same dat base (i + 1) else pure False
  chainStart (relFull rel) h >>= walk

-- | Append a tuple (from an array offset) to the pending buffer.
pushBuffer :: Relation s -> Arr s -> Int -> ST s ()
pushBuffer rel tup off = do
  let ar = relArity rel
  n <- unsafeRead (relMeta rel) 1
  buf <- ensureCap (relBuf rel) ((n + 1) * ar) 0
  forM_ [0 .. ar - 1] $ \i -> unsafeRead tup (off + i) >>= unsafeWrite buf (n * ar + i)
  unsafeWrite (relMeta rel) 1 (n + 1)

appendRow :: Relation s -> Arr s -> Int -> ST s ()
appendRow rel src off = do
  let ar = relArity rel
  n <- unsafeRead (relMeta rel) 0
  dat <- ensureCap (relRows rel) ((n + 1) * ar) 0
  forM_ [0 .. ar - 1] $ \i -> unsafeRead src (off + i) >>= unsafeWrite dat (n * ar + i)
  unsafeWrite (relMeta rel) 0 (n + 1)
  ixs <- readSTRef (relIndexes rel)
  forM_ ixs $ \ix -> indexInsert dat ar ix n

-- | Move buffered tuples into the relation (skipping duplicates) and
-- update every index.
flushBuffer :: Relation s -> ST s ()
flushBuffer rel = do
  n <- unsafeRead (relMeta rel) 1
  when (n > 0) $ do
    let ar = relArity rel
    buf <- readSTRef (relBuf rel)
    forM_ [0 .. n - 1] $ \i -> do
      m <- memberRow rel buf (i * ar)
      if m then pure () else appendRow rel buf (i * ar)
    unsafeWrite (relMeta rel) 1 0

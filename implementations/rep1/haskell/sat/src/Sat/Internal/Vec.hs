{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module      : Sat.Internal.Vec
-- Description : Growable unboxed vectors in 'ST' (internal).
module Sat.Internal.Vec
  ( Vec
  , newVec
  , vecSize
  , vecRead
  , vecWrite
  , vecPush
  , vecPop
  , vecTruncate
  , vecClear
  , vecData
  , vecSetSize
  , vecToList
  , vecFromList
  ) where

import Control.Monad (forM_)
import Control.Monad.ST (ST)
import Data.Array.Base (MArray, getNumElements, newArray, newArray_, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray)
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)

-- | A growable array with amortised O(1) 'vecPush'.
data Vec s a = Vec
  { vArr :: !(STRef s (STUArray s Int a))
  , vLen :: !(STUArray s Int Int)
  }

-- | A new empty vector with the given initial capacity.
newVec :: MArray (STUArray s) a (ST s) => Int -> ST s (Vec s a)
newVec cap = do
  arr <- newArray_ (0, max 1 cap - 1)
  r <- newSTRef arr
  l <- newArray (0, 0) 0
  return (Vec r l)
{-# INLINE newVec #-}

vecSize :: Vec s a -> ST s Int
vecSize v = unsafeRead (vLen v) 0
{-# INLINE vecSize #-}

-- | Current backing array. Valid until the next 'vecPush'.
vecData :: Vec s a -> ST s (STUArray s Int a)
vecData v = readSTRef (vArr v)
{-# INLINE vecData #-}

-- | Unchecked read.
vecRead :: MArray (STUArray s) a (ST s) => Vec s a -> Int -> ST s a
vecRead v i = do
  arr <- readSTRef (vArr v)
  unsafeRead arr i
{-# INLINE vecRead #-}

-- | Unchecked write to an existing index.
vecWrite :: MArray (STUArray s) a (ST s) => Vec s a -> Int -> a -> ST s ()
vecWrite v i x = do
  arr <- readSTRef (vArr v)
  unsafeWrite arr i x
{-# INLINE vecWrite #-}

vecPush :: MArray (STUArray s) a (ST s) => Vec s a -> a -> ST s ()
vecPush v x = do
  n <- unsafeRead (vLen v) 0
  arr <- readSTRef (vArr v)
  cap <- getNumElements arr
  arr' <-
    if n < cap
      then return arr
      else do
        new <- newArray_ (0, 2 * cap - 1)
        forM_ [0 .. n - 1] $ \i -> unsafeRead arr i >>= unsafeWrite new i
        writeSTRef (vArr v) new
        return new
  unsafeWrite arr' n x
  unsafeWrite (vLen v) 0 (n + 1)
{-# INLINE vecPush #-}

-- | Remove and return the last element (the vector must be non-empty).
vecPop :: MArray (STUArray s) a (ST s) => Vec s a -> ST s a
vecPop v = do
  n <- unsafeRead (vLen v) 0
  unsafeWrite (vLen v) 0 (n - 1)
  vecRead v (n - 1)
{-# INLINE vecPop #-}

-- | Shrink to the given length.
vecTruncate :: Vec s a -> Int -> ST s ()
vecTruncate v = unsafeWrite (vLen v) 0
{-# INLINE vecTruncate #-}

-- | Set the logical size (the elements must already have been written).
vecSetSize :: Vec s a -> Int -> ST s ()
vecSetSize = vecTruncate
{-# INLINE vecSetSize #-}

vecClear :: Vec s a -> ST s ()
vecClear v = vecTruncate v 0
{-# INLINE vecClear #-}

vecToList :: MArray (STUArray s) a (ST s) => Vec s a -> ST s [a]
vecToList v = do
  n <- vecSize v
  arr <- vecData v
  mapM (unsafeRead arr) [0 .. n - 1]

-- | Replace the contents of the vector.
vecFromList :: MArray (STUArray s) a (ST s) => Vec s a -> [a] -> ST s ()
vecFromList v xs = vecClear v >> mapM_ (vecPush v) xs

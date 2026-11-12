{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module      : Sat.Internal.Vec
-- Description : Growable mutable vectors in 'ST'.
--
-- A minimal amortised-O(1) push\/pop vector, generic over the underlying
-- mutable array type so the same code serves unboxed ('STUArray') and boxed
-- ('STArray') element types.  Internal to the solver; no bounds checking is
-- performed on 'vget' \/ 'vset'.
module Sat.Internal.Vec
  ( Vec
  , IntVec
  , newVec
  , vsize
  , vget
  , vset
  , vpush
  , vpop
  , vshrink
  , vclear
  , vdata
  ) where

import Control.Monad.ST (ST)
import Data.Array.Base (MArray, getNumElements, newArray, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray)
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)

-- | A growable vector.  The first field holds the logical size, the second
-- the current backing array, the third the filler used when growing.
data Vec a s e = Vec !(STUArray s Int Int) !(STRef s (a Int e)) !e

-- | A vector of unboxed 'Int's.
type IntVec s = Vec (STUArray s) s Int

-- | @newVec cap def@ creates an empty vector with room for @cap@ elements.
newVec :: MArray a e (ST s) => Int -> e -> ST s (Vec a s e)
newVec cap def = do
  sz <- newArray (0, 0) 0
  arr <- newArray (0, max 4 cap - 1) def
  ref <- newSTRef arr
  return (Vec sz ref def)
{-# INLINABLE newVec #-}

-- | Number of elements.
vsize :: Vec a s e -> ST s Int
vsize (Vec sz _ _) = unsafeRead sz 0
{-# INLINE vsize #-}

-- | The backing array (valid until the next 'vpush').
vdata :: Vec a s e -> ST s (a Int e)
vdata (Vec _ ref _) = readSTRef ref
{-# INLINE vdata #-}

-- | Read element @i@ (unchecked).
vget :: MArray a e (ST s) => Vec a s e -> Int -> ST s e
vget (Vec _ ref _) i = readSTRef ref >>= \arr -> unsafeRead arr i
{-# INLINE vget #-}

-- | Overwrite element @i@ (unchecked).
vset :: MArray a e (ST s) => Vec a s e -> Int -> e -> ST s ()
vset (Vec _ ref _) i x = readSTRef ref >>= \arr -> unsafeWrite arr i x
{-# INLINE vset #-}

-- | Append an element, growing the backing array geometrically.
vpush :: MArray a e (ST s) => Vec a s e -> e -> ST s ()
vpush (Vec sz ref def) x = do
  n <- unsafeRead sz 0
  arr <- readSTRef ref
  cap <- getNumElements arr
  if n < cap
    then unsafeWrite arr n x
    else do
      arr' <- newArray (0, 2 * cap - 1) def
      let copy i | i >= n = return ()
                 | otherwise = unsafeRead arr i >>= unsafeWrite arr' i >> copy (i + 1)
      copy 0
      unsafeWrite arr' n x
      writeSTRef ref arr'
  unsafeWrite sz 0 (n + 1)
{-# INLINABLE vpush #-}

-- | Remove and return the last element.  The vector must be non-empty.
vpop :: MArray a e (ST s) => Vec a s e -> ST s e
vpop v@(Vec sz _ _) = do
  n <- unsafeRead sz 0
  x <- vget v (n - 1)
  unsafeWrite sz 0 (n - 1)
  return x
{-# INLINABLE vpop #-}

-- | Truncate to the given size (which must not exceed the current size).
vshrink :: Vec a s e -> Int -> ST s ()
vshrink (Vec sz _ _) n = unsafeWrite sz 0 n
{-# INLINE vshrink #-}

-- | Remove all elements.
vclear :: Vec a s e -> ST s ()
vclear v = vshrink v 0
{-# INLINE vclear #-}

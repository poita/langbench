-- |
-- Module      : Sat.Internal.Heap
-- Description : Indexed binary max-heap of variables keyed by activity.
--
-- The VSIDS decision queue.  Keys live in an external activity array owned by
-- the solver; the heap stores variable numbers and remembers each variable's
-- position so that a key increase can be repaired in O(log n).
module Sat.Internal.Heap
  ( Heap
  , newHeap
  , member
  , insert
  , removeMax
  , increased
  ) where

import Control.Monad.ST (ST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)

-- | A max-heap over variables @0 .. n-1@ (or any ints below the capacity).
data Heap s = Heap
  { hElems :: !(STUArray s Int Int)     -- ^ heap-ordered array of variables
  , hPos   :: !(STUArray s Int Int)     -- ^ position of each variable, or -1
  , hSize  :: !(STUArray s Int Int)     -- ^ single cell: current size
  , hKey   :: !(STUArray s Int Double)  -- ^ external key (activity) array
  }

-- | @newHeap n keys@ makes an empty heap that can hold variables @< n@.
newHeap :: Int -> STUArray s Int Double -> ST s (Heap s)
newHeap n keys = do
  es <- newArray (0, max 1 n - 1) 0
  ps <- newArray (0, max 1 n - 1) (-1)
  sz <- newArray (0, 0) 0
  return (Heap es ps sz keys)

-- | Is the variable currently in the heap?
member :: Heap s -> Int -> ST s Bool
member h v = (>= 0) <$> unsafeRead (hPos h) v
{-# INLINE member #-}

-- | Insert a variable (no-op if already present).
insert :: Heap s -> Int -> ST s ()
insert h v = do
  p <- unsafeRead (hPos h) v
  if p >= 0
    then return ()
    else do
      n <- unsafeRead (hSize h) 0
      unsafeWrite (hSize h) 0 (n + 1)
      siftUp h n v

-- | Remove and return the variable with the greatest key, if any.
removeMax :: Heap s -> ST s (Maybe Int)
removeMax h = do
  n <- unsafeRead (hSize h) 0
  if n == 0
    then return Nothing
    else do
      top <- unsafeRead (hElems h) 0
      lastV <- unsafeRead (hElems h) (n - 1)
      unsafeWrite (hPos h) top (-1)
      unsafeWrite (hSize h) 0 (n - 1)
      if n > 1 then siftDown h 0 lastV (n - 1) else return ()
      return (Just top)

-- | Tell the heap that the key of @v@ has increased.
increased :: Heap s -> Int -> ST s ()
increased h v = do
  p <- unsafeRead (hPos h) v
  if p >= 0 then siftUp h p v else return ()

-- Place @v@ at or above position @i@, moving larger-key ancestors down.
siftUp :: Heap s -> Int -> Int -> ST s ()
siftUp h i0 v = do
  kv <- unsafeRead (hKey h) v
  let go i
        | i == 0 = place i
        | otherwise = do
            let par = (i - 1) `div` 2
            pv <- unsafeRead (hElems h) par
            kp <- unsafeRead (hKey h) pv
            if kv > kp
              then unsafeWrite (hElems h) i pv >> unsafeWrite (hPos h) pv i >> go par
              else place i
      place i = unsafeWrite (hElems h) i v >> unsafeWrite (hPos h) v i
  go i0

-- Place @v@ at or below position @i@ in a heap of size @n@.
siftDown :: Heap s -> Int -> Int -> Int -> ST s ()
siftDown h i0 v n = do
  kv <- unsafeRead (hKey h) v
  let go i = do
        let l = 2 * i + 1
            r = l + 1
        if l >= n
          then place i
          else do
            lv <- unsafeRead (hElems h) l
            kl <- unsafeRead (hKey h) lv
            (c, cv, kc) <-
              if r < n
                then do
                  rv <- unsafeRead (hElems h) r
                  kr <- unsafeRead (hKey h) rv
                  return (if kr > kl then (r, rv, kr) else (l, lv, kl))
                else return (l, lv, kl)
            if kc > kv
              then unsafeWrite (hElems h) i cv >> unsafeWrite (hPos h) cv i >> go c
              else place i
      place i = unsafeWrite (hElems h) i v >> unsafeWrite (hPos h) v i
  go i0

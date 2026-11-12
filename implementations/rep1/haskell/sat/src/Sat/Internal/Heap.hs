-- |
-- Module      : Sat.Internal.Heap
-- Description : Indexed binary max-heap of variables keyed by activity (internal).
--
-- The VSIDS decision queue. Variables are @0..n-1@; the key of variable @v@
-- is read from a shared activity array, so after the activity of a variable
-- that is in the heap has increased, call 'heapIncreased'.
module Sat.Internal.Heap
  ( Heap
  , newHeap
  , heapInsert
  , heapIncreased
  , heapRemoveMax
  ) where

import Control.Monad.ST (ST)
import Data.Array.Base (newArray, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray)

data Heap s = Heap
  { hHeap :: !(STUArray s Int Int)     -- ^ heap-ordered variables
  , hPos  :: !(STUArray s Int Int)     -- ^ position of each variable, or -1
  , hSize :: !(STUArray s Int Int)     -- ^ single cell: number of elements
  , hAct  :: !(STUArray s Int Double)  -- ^ activities (shared with the solver)
  }

-- | An empty heap able to hold variables @0..n-1@ ordered by the given
-- activity array.
newHeap :: Int -> STUArray s Int Double -> ST s (Heap s)
newHeap n act = do
  h <- newArray (0, max 1 n - 1) 0
  p <- newArray (0, max 1 n - 1) (-1)
  s <- newArray (0, 0) 0
  return (Heap h p s act)

-- | Insert a variable unless it is already present.
heapInsert :: Heap s -> Int -> ST s ()
heapInsert hp v = do
  p <- unsafeRead (hPos hp) v
  if p >= 0
    then return ()
    else do
      n <- unsafeRead (hSize hp) 0
      unsafeWrite (hHeap hp) n v
      unsafeWrite (hPos hp) v n
      unsafeWrite (hSize hp) 0 (n + 1)
      percolateUp hp n

-- | Restore the heap property after the activity of @v@ increased.
heapIncreased :: Heap s -> Int -> ST s ()
heapIncreased hp v = do
  p <- unsafeRead (hPos hp) v
  if p >= 0 then percolateUp hp p else return ()

-- | Remove and return the variable of highest activity, or @-1@ if empty.
heapRemoveMax :: Heap s -> ST s Int
heapRemoveMax hp = do
  n <- unsafeRead (hSize hp) 0
  if n == 0
    then return (-1)
    else do
      x <- unsafeRead (hHeap hp) 0
      lastV <- unsafeRead (hHeap hp) (n - 1)
      unsafeWrite (hSize hp) 0 (n - 1)
      unsafeWrite (hPos hp) x (-1)
      if n > 1
        then do
          unsafeWrite (hHeap hp) 0 lastV
          unsafeWrite (hPos hp) lastV 0
          percolateDown hp 0
        else return ()
      return x

percolateUp :: Heap s -> Int -> ST s ()
percolateUp hp i0 = do
  x <- unsafeRead (hHeap hp) i0
  ax <- unsafeRead (hAct hp) x
  let go i
        | i == 0 = return i
        | otherwise = do
            let par = (i - 1) `div` 2
            y <- unsafeRead (hHeap hp) par
            ay <- unsafeRead (hAct hp) y
            if ax > ay
              then do
                unsafeWrite (hHeap hp) i y
                unsafeWrite (hPos hp) y i
                go par
              else return i
  i' <- go i0
  unsafeWrite (hHeap hp) i' x
  unsafeWrite (hPos hp) x i'

percolateDown :: Heap s -> Int -> ST s ()
percolateDown hp i0 = do
  n <- unsafeRead (hSize hp) 0
  x <- unsafeRead (hHeap hp) i0
  ax <- unsafeRead (hAct hp) x
  let go i = do
        let l = 2 * i + 1
            r = l + 1
        if l >= n
          then return i
          else do
            yl <- unsafeRead (hHeap hp) l
            al <- unsafeRead (hAct hp) yl
            (c, yc, ac) <-
              if r < n
                then do
                  yr <- unsafeRead (hHeap hp) r
                  ar <- unsafeRead (hAct hp) yr
                  return (if ar > al then (r, yr, ar) else (l, yl, al))
                else return (l, yl, al)
            if ac > ax
              then do
                unsafeWrite (hHeap hp) i yc
                unsafeWrite (hPos hp) yc i
                go c
              else return i
  i' <- go i0
  unsafeWrite (hHeap hp) i' x
  unsafeWrite (hPos hp) x i'

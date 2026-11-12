{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
-- | A minimal wrapper over GHC's @SmallArray#@: immutable arrays of boxed
-- values with O(1) indexing and no per-array bounds, used for the fields of
-- tuples, structs, enum values and closures.
module Langvm.SmallArray
  ( SmallArray
  , sizeA
  , indexA
  , emptyA
  , fromListA
  , toListA
  , MutArr
  , newMutA
  , writeMutA
  , freezeA
  ) where

import GHC.Exts
import GHC.IO (IO (..))

data SmallArray a = SmallArray (SmallArray# a)

data MutArr a = MutArr (SmallMutableArray# RealWorld a)

sizeA :: SmallArray a -> Int
sizeA (SmallArray a) = I# (sizeofSmallArray# a)
{-# INLINE sizeA #-}

indexA :: SmallArray a -> Int -> a
indexA (SmallArray a) (I# i) = case indexSmallArray# a i of (# x #) -> x
{-# INLINE indexA #-}

emptyA :: SmallArray a
emptyA = fromListA 0 []
{-# NOINLINE emptyA #-}

-- | Build an array of the given length from the first elements of a list.
fromListA :: Int -> [a] -> SmallArray a
fromListA n xs = case unsafeDupableRun (do
    m <- newMutA n (errorElem)
    let go _ [] = return ()
        go i (y : ys) | i >= n = return ()
                      | otherwise = writeMutA m i y >> go (i + 1) ys
    go 0 xs
    freezeA m) of r -> r

unsafeDupableRun :: IO a -> a
unsafeDupableRun (IO f) = case runRW# f of (# _, a #) -> a
{-# INLINE unsafeDupableRun #-}

errorElem :: a
errorElem = error "Langvm.SmallArray: uninitialised element"

toListA :: SmallArray a -> [a]
toListA arr = [indexA arr i | i <- [0 .. sizeA arr - 1]]

newMutA :: Int -> a -> IO (MutArr a)
newMutA (I# n) x = IO $ \s -> case newSmallArray# n x s of
  (# s', m #) -> (# s', MutArr m #)
{-# INLINE newMutA #-}

writeMutA :: MutArr a -> Int -> a -> IO ()
writeMutA (MutArr m) (I# i) x = IO $ \s -> case writeSmallArray# m i x s of
  s' -> (# s', () #)
{-# INLINE writeMutA #-}

-- | Freeze without copying; the mutable array must not be written afterwards.
freezeA :: MutArr a -> IO (SmallArray a)
freezeA (MutArr m) = IO $ \s -> case unsafeFreezeSmallArray# m s of
  (# s', a #) -> (# s', SmallArray a #)
{-# INLINE freezeA #-}

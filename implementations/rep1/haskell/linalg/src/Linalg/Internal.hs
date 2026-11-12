{-# LANGUAGE BangPatterns #-}
-- | Small helpers shared by the numerical kernels. Not part of the public API.
module Linalg.Internal
  ( forN
  , forDown
  , rd
  , wr
  , STU
  ) where

import Control.Monad.ST (ST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray)

-- | A mutable unboxed array of doubles indexed from 0.
type STU s = STUArray s Int Double

-- | @forN a b f@ runs @f i@ for @i = a, a+1 .. b-1@.
forN :: Int -> Int -> (Int -> ST s ()) -> ST s ()
forN !a !b f = go a
  where
    go !i
      | i >= b = pure ()
      | otherwise = f i >> go (i + 1)
{-# INLINE forN #-}

-- | @forDown a b f@ runs @f i@ for @i = a, a-1 .. b@.
forDown :: Int -> Int -> (Int -> ST s ()) -> ST s ()
forDown !a !b f = go a
  where
    go !i
      | i < b = pure ()
      | otherwise = f i >> go (i - 1)
{-# INLINE forDown #-}

-- | Unchecked read.
rd :: STU s -> Int -> ST s Double
rd = unsafeRead
{-# INLINE rd #-}

-- | Unchecked write.
wr :: STU s -> Int -> Double -> ST s ()
wr = unsafeWrite
{-# INLINE wr #-}

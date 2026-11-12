-- |
-- Module      : Depresolve.Resolve
-- Description : The depth-first, newest-first, backtracking search.
--
-- This is a direct, iterative transcription of the specified recursion:
--
-- * pending requirements are an immutable list shared between choice points
--   (a newly chosen version's requirements are prepended);
-- * the chosen versions live in a mutable array and are undone through a
--   trail, so no state is copied at a choice point;
-- * choice points live on an explicit stack, so recursion depth is limited
--   only by memory.
module Depresolve.Resolve
  ( resolveIndex
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST, runST)
import Data.Array
import Data.Array.ST (STUArray, newArray, readArray, writeArray)

import Depresolve.Index

-- | A choice point: the package, the candidate index currently tried, the end
-- of its candidate block, the pending requirements that follow its own, and
-- the trail height before the package was assigned.
data Choice
  = Choice
      {-# UNPACK #-} !Int -- package id
      {-# UNPACK #-} !Int -- candidate index currently tried
      {-# UNPACK #-} !Int -- end (exclusive) of the candidate block
      [Req]               -- pending requirements after the package's own
      {-# UNPACK #-} !Int -- trail height before the assignment

-- | Run the search.  Returns, for every chosen package, its id and the index
-- of its chosen version in newest-first order (ascending by package id), or
-- 'Nothing' if the search fails.
resolveIndex :: Index -> Maybe [(Int, Int)]
resolveIndex ix = runST $ do
  chosen <- newArray (0, max 0 (n - 1)) (-1) :: ST s (STUArray s Int Int)
  trail <- newArray (0, max 0 n) 0 :: ST s (STUArray s Int Int)
  top <- newArray (0, 0) 0 :: ST s (STUArray s Int Int)

  let -- assign candidate @i@ to package @p@ and record it on the trail
      assign p i = do
        writeArray chosen p i
        t <- readArray top 0
        writeArray trail t p
        writeArray top 0 (t + 1)

      -- undo trail entries down to height @h@
      unwind h = do
        t <- readArray top 0
        when (t > h) $ do
          p <- readArray trail (t - 1)
          writeArray chosen p (-1)
          writeArray top 0 (t - 1)
          unwind h

      go [] _ = do
        r <- mapM (\p -> fmap ((,) p) (readArray chosen p)) [0 .. n - 1]
        return (Just [(p, c) | (p, c) <- r, c >= 0])
      go (Req p lo hi : rest) cs = do
        c <- readArray chosen p
        if c >= 0
          then if c >= lo && c < hi then go rest cs else backtrack cs
          else
            if lo >= hi
              then backtrack cs
              else do
                h <- readArray top 0
                assign p lo
                let cs' = if lo + 1 < hi then Choice p lo hi rest h : cs else cs
                go (ixDeps ix ! versionSlot ix p lo ++ rest) cs'

      backtrack [] = return Nothing
      backtrack (Choice p i hi rest h : cs) = do
        unwind h
        let i' = i + 1
        assign p i'
        let cs' = if i' + 1 < hi then Choice p i' hi rest h : cs else cs
        go (ixDeps ix ! versionSlot ix p i' ++ rest) cs'

  go (ixRoot ix) []
  where
    n = rangeSize (bounds (ixNames ix))

{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Diff.Myers
-- Description : Linear-space Myers diff on integer sequences.
--
-- An implementation of the O(ND) difference algorithm of E. Myers,
-- /An O(ND) Difference Algorithm and Its Variations/ (Algorithmica, 1986) in
-- its linear-space divide-and-conquer form (section 4b).  The problem is
-- split at a /middle snake/: forward and reverse searches run from the two
-- corners of the edit graph, each for about D/2 rounds, until they overlap.
-- The overlap point lies on a shortest path, so the two halves are solved
-- recursively.  Common prefixes and suffixes are trimmed at every level.
--
-- The result is always /exact/ (a shortest edit script) and there are no
-- heuristic cut-offs.  Time is O((N+M)·D), working space O(N+M), and the
-- recursion depth O(log D).  Comparison of two elements is a single 'Int'
-- comparison, which is why the input is given as integer ids (see
-- "Diff.Intern").
module Diff.Myers
  ( diffIds
  ) where

import           Control.Monad.ST      (ST, runST)
import           Data.Array.Base       (unsafeAt, unsafeRead, unsafeWrite)
import           Data.Array.ST         (STUArray, newArray)
import           Data.Array.Unboxed    (UArray, bounds)

import           Diff.Types

-- | Shortest edit script between two 0-indexed integer sequences.
--
-- In the result, @'Keep' i@ and @'Delete' i@ refer to index @i@ of the first
-- sequence and @'Insert' j@ to index @j@ of the second.  Reading the 'Keep'
-- and 'Delete' indices left to right yields @0 .. n-1@ in order, and reading
-- the 'Keep' and 'Insert' steps yields every element of the second sequence in
-- order; every 'Keep' pairs equal elements.
diffIds :: UArray Int Int -> UArray Int Int -> [Edit Int]
diffIds as bs = runST (go 0 n 0 m [])
  where
    n = size as
    m = size bs

    -- Solve a[a0,a1) vs b[b0,b1), prepending the script to @rest@.
    go :: Int -> Int -> Int -> Int -> [Edit Int] -> ST s [Edit Int]
    go !a0 !a1 !b0 !b1 rest = do
      let !p  = prefixLen a0 a1 b0 b1
          !a0' = a0 + p
          !b0' = b0 + p
          !s  = suffixLen a0' a1 b0' b1
          !a1' = a1 - s
          !b1' = b1 - s
          tailKeeps = [Keep i | i <- [a1' .. a1 - 1]] ++ rest
      mid <- middle a0' a1' b0' b1' tailKeeps
      return ([Keep i | i <- [a0 .. a0' - 1]] ++ mid)

    -- Solve a problem with no common prefix or suffix.
    middle :: Int -> Int -> Int -> Int -> [Edit Int] -> ST s [Edit Int]
    middle !a0 !a1 !b0 !b1 rest
      | a0 >= a1  = return ([Insert j | j <- [b0 .. b1 - 1]] ++ rest)
      | b0 >= b1  = return ([Delete i | i <- [a0 .. a1 - 1]] ++ rest)
      | otherwise = do
          (x, y) <- split a0 a1 b0 b1
          right  <- go x a1 y b1 rest
          go a0 x b0 y right

    prefixLen a0 a1 b0 b1 = loop 0
      where
        lim = min (a1 - a0) (b1 - b0)
        loop !k | k < lim && unsafeAt as (a0 + k) == unsafeAt bs (b0 + k) = loop (k + 1)
                | otherwise = k

    suffixLen a0 a1 b0 b1 = loop 0
      where
        lim = min (a1 - a0) (b1 - b0)
        loop !k | k < lim && unsafeAt as (a1 - 1 - k) == unsafeAt bs (b1 - 1 - k) = loop (k + 1)
                | otherwise = k

    -- Find a point (x, y) of the edit graph, in absolute coordinates, that
    -- lies on a shortest path and strictly divides the problem.  Requires
    -- both ranges non-empty with no common first or last element.
    split :: forall s. Int -> Int -> Int -> Int -> ST s (Int, Int)
    split !a0 !a1 !b0 !b1 = do
      let !w     = a1 - a0
          !h     = b1 - b0
          !maxD  = (w + h + 1) `div` 2
          !off   = maxD + 1
          !len   = 2 * maxD + 3
          !delta = w - h
          !front = odd delta
      v1 <- newArray (0, len - 1) (-1) :: ST s (STUArray s Int Int)
      v2 <- newArray (0, len - 1) (-1) :: ST s (STUArray s Int Int)
      unsafeWrite v1 (off + 1) 0
      unsafeWrite v2 (off + 1) 0
      let -- furthest-reaching x after following the forward snake from (x, y)
          fsnake !x !y
            | x < w && y < h && unsafeAt as (a0 + x) == unsafeAt bs (b0 + y) = fsnake (x + 1) (y + 1)
            | otherwise = x
          -- the same for the reverse search (on the reversed sequences)
          rsnake !x !y
            | x < w && y < h && unsafeAt as (a1 - 1 - x) == unsafeAt bs (b1 - 1 - y) = rsnake (x + 1) (y + 1)
            | otherwise = x

          -- Rounds; ks/ke trim diagonals that have run off the grid.
          rounds :: Int -> Int -> Int -> Int -> Int -> ST s (Int, Int)
          rounds !d !k1s !k1e !k2s !k2e
            | d >= maxD = return (a0, b1)   -- no commonality: delete all, insert all
            | otherwise = do
                r1 <- forward d (negate d + k1s) (d - k1e) k1s k1e
                case r1 of
                  Left pt -> return pt
                  Right (k1s', k1e') -> do
                    r2 <- reverse' d (negate d + k2s) (d - k2e) k2s k2e
                    case r2 of
                      Left pt -> return pt
                      Right (k2s', k2e') -> rounds (d + 1) k1s' k1e' k2s' k2e'

          forward :: Int -> Int -> Int -> Int -> Int -> ST s (Either (Int, Int) (Int, Int))
          forward !d !k !lim !s !e
            | k > lim = return (Right (s, e))
            | otherwise = do
                let !ko = off + k
                l <- unsafeRead v1 (ko - 1)
                r <- unsafeRead v1 (ko + 1)
                let !x0 = if k == negate d || (k /= d && l < r) then r else l + 1
                    !x1 = fsnake x0 (x0 - k)
                    !y1 = x1 - k
                unsafeWrite v1 ko x1
                if x1 > w then forward d (k + 2) lim s (e + 2)
                else if y1 > h then forward d (k + 2) lim (s + 2) e
                else if front then do
                  let !k2o = off + delta - k
                  if k2o >= 0 && k2o < len
                    then do
                      x2 <- unsafeRead v2 k2o
                      if x2 /= -1 && x1 >= w - x2
                        then return (Left (a0 + x1, b0 + y1))
                        else forward d (k + 2) lim s e
                    else forward d (k + 2) lim s e
                else forward d (k + 2) lim s e

          reverse' :: Int -> Int -> Int -> Int -> Int -> ST s (Either (Int, Int) (Int, Int))
          reverse' !d !k !lim !s !e
            | k > lim = return (Right (s, e))
            | otherwise = do
                let !ko = off + k
                l <- unsafeRead v2 (ko - 1)
                r <- unsafeRead v2 (ko + 1)
                let !x0 = if k == negate d || (k /= d && l < r) then r else l + 1
                    !x2 = rsnake x0 (x0 - k)
                    !y2 = x2 - k
                unsafeWrite v2 ko x2
                if x2 > w then reverse' d (k + 2) lim s (e + 2)
                else if y2 > h then reverse' d (k + 2) lim (s + 2) e
                else if not front then do
                  let !k1o = off + delta - k
                  if k1o >= 0 && k1o < len
                    then do
                      x1 <- unsafeRead v1 k1o
                      if x1 /= -1 && x1 >= w - x2
                        then return (Left (a0 + x1, b0 + (x1 - (delta - k))))
                        else reverse' d (k + 2) lim s e
                    else reverse' d (k + 2) lim s e
                else reverse' d (k + 2) lim s e
      rounds 0 0 0 0 0

size :: UArray Int Int -> Int
size arr = let (lo, hi) = bounds arr in hi - lo + 1

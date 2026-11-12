-- |
-- Module      : Rubiks.Internal.Combinatorics
-- Description : Ranking of subsets and permutations.
--
-- Small helpers used to turn pieces of cube state into dense integer
-- coordinates.  Not part of the stable API.
module Rubiks.Internal.Combinatorics
  ( choose
  , rankSubset
  , unrankSubset
  , rankPermutation
  , unrankPermutation
  , permutationParity
  ) where

import Data.List (sort)

-- | Binomial coefficient; @choose n k == 0@ when @k > n@ or @k < 0@.
choose :: Int -> Int -> Int
choose n k
  | k < 0 || k > n = 0
  | otherwise = go 1 1
  where
    k' = min k (n - k)
    go i acc
      | i > k' = acc
      | otherwise = go (i + 1) (acc * (n - k' + i) `div` i)

-- | Rank of a set of distinct non-negative integers (in any order) among all
-- sets of the same size, via the combinatorial number system.  The rank of a
-- @k@-subset of @[0, n)@ is in @[0, choose n k)@.
rankSubset :: [Int] -> Int
rankSubset xs = sum [choose p i | (i, p) <- zip [1 ..] (sort xs)]

-- | @unrankSubset n k r@ is the @k@-subset of @[0, n)@ (ascending) with rank @r@.
unrankSubset :: Int -> Int -> Int -> [Int]
unrankSubset n k0 r0 = reverse (go (n - 1) k0 r0)
  where
    go _ 0 _ = []
    go p k r
      | choose p k > r = go (p - 1) k r
      | otherwise = p : go (p - 1) (k - 1) (r - choose p k)

-- | Lehmer-code rank of a permutation of @[0, n)@, in @[0, n!)@.
rankPermutation :: [Int] -> Int
rankPermutation = go
  where
    go [] = 0
    go (x : xs) = length (filter (< x) xs) * factorial (length xs) + go xs

-- | @unrankPermutation n r@ is the permutation of @[0, n)@ with rank @r@.
unrankPermutation :: Int -> Int -> [Int]
unrankPermutation n = go [0 .. n - 1]
  where
    go [] _ = []
    go avail r =
      let f = factorial (length avail - 1)
          (q, r') = r `divMod` f
          x = avail !! q
       in x : go (take q avail ++ drop (q + 1) avail) r'

-- | Parity of a permutation of @[0, n)@: 0 for even, 1 for odd.
permutationParity :: [Int] -> Int
permutationParity xs =
  length [() | (i, x) <- zip [0 :: Int ..] xs, y <- drop (i + 1) xs, x > y] `mod` 2

factorial :: Int -> Int
factorial n = product [1 .. n]

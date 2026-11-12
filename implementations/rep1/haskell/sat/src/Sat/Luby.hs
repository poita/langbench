-- |
-- Module      : Sat.Luby
-- Description : The Luby restart sequence.
module Sat.Luby
  ( luby
  , lubySequence
  ) where

-- | @luby y i@ is the @i@-th (zero-based) element of the Luby sequence
-- scaled by base @y@: for @y = 2@ it is @1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...@.
--
-- Restart @i@ of the solver allows @100 * luby 2 i@ conflicts.
luby :: Int -> Int -> Int
luby y x0 = go size0 seq0 x0
  where
    -- Find the smallest complete subsequence (length 2^k - 1) containing x0.
    (size0, seq0) = grow 1 (0 :: Int)
    grow size sq
      | size < x0 + 1 = grow (2 * size + 1) (sq + 1)
      | otherwise     = (size, sq)
    go size sq x
      | size - 1 == x = y ^ sq
      | otherwise     =
          let size' = (size - 1) `div` 2
          in go size' (sq - 1) (x `mod` size')

-- | The infinite Luby sequence for the given base.
lubySequence :: Int -> [Int]
lubySequence y = map (luby y) [0 ..]

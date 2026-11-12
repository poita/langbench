-- |
-- Module      : Spiremark.Random
-- Description : The 64-bit xorshift* generator of SPEC.md section 25.
module Spiremark.Random
  ( Rng
  , mkRng
  , nextWord
  , below
  , shuffle
  ) where

import Data.Bits (shiftL, shiftR, xor)
import qualified Data.IntMap.Strict as M
import Data.Word (Word64)

-- | Generator state.
newtype Rng = Rng Word64
  deriving (Eq, Show)

multiplier :: Word64
multiplier = 0x2545F4914F6CDD1D

-- | Seed a generator; a zero seed is replaced by the multiplier constant.
mkRng :: Word64 -> Rng
mkRng 0 = Rng multiplier
mkRng s = Rng s

-- | Next raw 64-bit value.
nextWord :: Rng -> (Word64, Rng)
nextWord (Rng s0) = (s3 * multiplier, Rng s3)
  where
    s1 = s0 `xor` (s0 `shiftR` 12)
    s2 = s1 `xor` (s1 `shiftL` 25)
    s3 = s2 `xor` (s2 `shiftR` 27)

-- | @below n@ for @n >= 1@: a value in @[0, n)@.
below :: Int -> Rng -> (Int, Rng)
below n g =
  let (w, g') = nextWord g
   in (fromIntegral (w `mod` fromIntegral n), g')

-- | Fisher-Yates shuffle exactly as specified (lists of length 0 or 1 consume
-- no randomness).
shuffle :: [a] -> Rng -> ([a], Rng)
shuffle xs g0
  | k <= 1 = (xs, g0)
  | otherwise = go (k - 1) (M.fromList (zip [0 ..] xs)) g0
  where
    k = length xs
    go i m g
      | i < 1 = (map (m M.!) [0 .. k - 1], g)
      | otherwise =
          let (j, g') = below (i + 1) g
              a = m M.! i
              b = m M.! j
           in go (i - 1) (M.insert i b (M.insert j a m)) g'

{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Numeric.BigInt.Magnitude
-- Description : Unsigned arbitrary-precision arithmetic in base 10^9.
--
-- A 'Mag' is a non-negative integer stored as little-endian limbs in base
-- @10^9@.  The representation is always normalised: there are no most
-- significant zero limbs, so zero is the empty limb sequence.  Because the
-- base is a power of ten, conversion from and to decimal text is linear.
--
-- The algorithms are the classical ones:
--
--   * 'addMag' and 'subMag' are linear carry\/borrow loops;
--   * 'mulMag' is schoolbook long multiplication, @O(n*m)@;
--   * 'quotRemMag' is Knuth's Algorithm D (TAOCP vol. 2, 4.3.1), producing
--     each quotient limb in constant time from a two-limb estimate;
--   * 'powMag' is left-to-right binary exponentiation.
--
-- Only fixed-width machine integers ('Word', 'Int') are used for limb
-- arithmetic.
module Numeric.BigInt.Magnitude
  ( Mag
  , base
    -- * Construction and inspection
  , zeroMag
  , oneMag
  , isZeroMag
  , fromWord
  , toWordMaybe
  , limbCount
  , fromDecimal
  , toDecimal
    -- * Arithmetic
  , compareMag
  , addMag
  , subMag
  , mulMag
  , mulSmall
  , quotRemMag
  , quotRemSmall
  , powMag
  ) where

import Control.Monad (when, forM_)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray)
import Data.Array.Unsafe (unsafeFreeze)
import Data.Bits (countLeadingZeros, finiteBitSize, testBit)
import Data.Array.Unboxed (UArray, bounds, listArray)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)
import Foreign.Storable (pokeByteOff)

-- | The limb base, @10^9@.
base :: Word
base = 1000000000
{-# INLINE base #-}

-- | Non-negative integer, little-endian limbs in base 'base', normalised
-- (no high zero limbs).
newtype Mag = Mag (UArray Int Word)

instance Eq Mag where
  a == b = compareMag a b == EQ

instance Ord Mag where
  compare = compareMag

instance Show Mag where
  show = map (toEnum . fromIntegral) . B.unpack . toDecimal

-- | Number of limbs.
limbCount :: Mag -> Int
limbCount (Mag a) = case bounds a of (_, hi) -> hi + 1
{-# INLINE limbCount #-}

limb :: Mag -> Int -> Word
limb (Mag a) i = unsafeAt a i
{-# INLINE limb #-}

zeroMag, oneMag :: Mag
zeroMag = Mag (listArray (0, -1) [])
oneMag = Mag (listArray (0, 0) [1])

isZeroMag :: Mag -> Bool
isZeroMag m = limbCount m == 0

-- | Build a magnitude from a mutable array of the given size, trimming
-- high zero limbs.
trim :: UArray Int Word -> Mag
trim arr = go hi
  where
    hi = case bounds arr of (_, h) -> h
    go !i | i < 0 = zeroMag
          | unsafeAt arr i /= 0 = if i == hi then Mag arr else Mag (listArray (0, i) [unsafeAt arr k | k <- [0 .. i]])
          | otherwise = go (i - 1)

-- | Convert a machine word.
fromWord :: Word -> Mag
fromWord 0 = zeroMag
fromWord w
  | w < base = Mag (listArray (0, 0) [w])
  | w < base * base = Mag (listArray (0, 1) [w `rem` base, w `quot` base])
  | otherwise = Mag (listArray (0, 2) [w `rem` base, (w `quot` base) `rem` base, w `quot` (base * base)])

-- | Convert to a machine word if it fits.
toWordMaybe :: Mag -> Maybe Word
toWordMaybe m = case limbCount m of
  0 -> Just 0
  1 -> Just (limb m 0)
  2 -> Just (limb m 0 + base * limb m 1)
  3 | limb m 2 <= 18 -> Just (limb m 0 + base * (limb m 1 + base * limb m 2))
  _ -> Nothing

-- | Parse a string of ASCII digits (no sign; leading zeros allowed; the
-- empty string is zero).  Behaviour on other bytes is unspecified.
fromDecimal :: B.ByteString -> Mag
fromDecimal s0 = trim arr
  where
    s = B.dropWhile (== 48) s0
    len = B.length s
    n = (len + 8) `quot` 9
    arr = runSTUArray $ do
      a <- newArray (0, n - 1) 0
      forM_ [0 .. n - 1] $ \i -> do
        let hi = len - 9 * i
            lo = max 0 (hi - 9)
            go !acc !k | k >= hi = acc
                       | otherwise = go (acc * 10 + fromIntegral (BU.unsafeIndex s k - 48)) (k + 1)
        unsafeWrite a i (go 0 lo)
      return a

-- | Render in decimal, without sign or leading zeros (zero is @"0"@).
toDecimal :: Mag -> B.ByteString
toDecimal m
  | n == 0 = B.singleton 48
  | otherwise = BI.unsafeCreate total $ \p -> do
      let top = limb m (n - 1)
          topDigits = digitsOf top
          writeW :: Int -> Int -> Word -> IO ()
          writeW off cnt w = go (off + cnt - 1) w cnt
            where
              go !pos !v !c = when (c > 0) $ do
                pokeByteOff p pos (fromIntegral (v `rem` 10) + 48 :: Word8)
                go (pos - 1) (v `quot` 10) (c - 1)
      writeW 0 topDigits top
      forM_ [1 .. n - 1] $ \k -> writeW (topDigits + 9 * (k - 1)) 9 (limb m (n - 1 - k))
  where
    n = limbCount m
    digitsOf :: Word -> Int
    digitsOf w = length (takeWhile (> 0) (iterate (`quot` 10) w))
    total = digitsOf (limb m (n - 1)) + 9 * (n - 1)

-- | Three-way comparison.
compareMag :: Mag -> Mag -> Ordering
compareMag a b = case compare (limbCount a) (limbCount b) of
  EQ -> go (limbCount a - 1)
  o -> o
  where
    go !i | i < 0 = EQ
          | x /= y = compare x y
          | otherwise = go (i - 1)
      where x = limb a i
            y = limb b i

-- | Sum.
addMag :: Mag -> Mag -> Mag
addMag a b
  | limbCount a < limbCount b = addMag b a
  | isZeroMag b = a
  | otherwise = trim $ runSTUArray $ do
      let na = limbCount a
          nb = limbCount b
      r <- newArray (0, na) 0
      let go !i !c
            | i >= na = unsafeWrite r i c
            | otherwise = do
                let s = limb a i + (if i < nb then limb b i else 0) + c
                if s >= base
                  then unsafeWrite r i (s - base) >> go (i + 1) 1
                  else unsafeWrite r i s >> go (i + 1) 0
      go 0 0
      return r

-- | Difference @a - b@.  Requires @a >= b@ (otherwise the result is
-- unspecified).
subMag :: Mag -> Mag -> Mag
subMag a b
  | isZeroMag b = a
  | otherwise = trim $ runSTUArray $ do
      let na = limbCount a
          nb = limbCount b
      r <- newArray (0, na - 1) 0
      let go !i !br
            | i >= na = return ()
            | otherwise = do
                let x = limb a i
                    y = (if i < nb then limb b i else 0) + br
                if x >= y
                  then unsafeWrite r i (x - y) >> go (i + 1) 0
                  else unsafeWrite r i (x + base - y) >> go (i + 1) 1
      go 0 0
      return r

-- | Product, by schoolbook long multiplication.
mulMag :: Mag -> Mag -> Mag
mulMag a b
  | isZeroMag a || isZeroMag b = zeroMag
  | limbCount a < limbCount b = mulMag b a
  | otherwise = trim $ runSTUArray $ do
      let na = limbCount a
          nb = limbCount b
      r <- newArray (0, na + nb - 1) 0
      forM_ [0 .. nb - 1] $ \j -> do
        let y = limb b j
            go !i !c
              | i >= na = unsafeWrite r (j + na) c
              | otherwise = do
                  o <- unsafeRead r (i + j)
                  let t = limb a i * y + o + c
                      (q, rm) = t `quotRem` base
                  unsafeWrite r (i + j) rm
                  go (i + 1) q
        when (y /= 0) $ go 0 0
      return r

-- | Multiply by a single limb value (@< 'base'@).
mulSmall :: Mag -> Word -> Mag
mulSmall a w
  | w == 0 || isZeroMag a = zeroMag
  | otherwise = trim $ runSTUArray $ do
      let na = limbCount a
      r <- newArray (0, na) 0
      let go !i !c
            | i >= na = unsafeWrite r i c
            | otherwise = do
                let (q, rm) = (limb a i * w + c) `quotRem` base
                unsafeWrite r i rm
                go (i + 1) q
      go 0 0
      return r

-- | Divide by a single limb value (@0 < d < 'base'@), giving quotient and
-- remainder.
quotRemSmall :: Mag -> Word -> (Mag, Word)
quotRemSmall a d = (trim q, rm)
  where
    na = limbCount a
    (q, rm) = runST $ do
      r <- newArray (0, na - 1) 0 :: ST s (STUArray s Int Word)
      let go !i !rem'
            | i < 0 = return rem'
            | otherwise = do
                let (qq, rr) = (rem' * base + limb a i) `quotRem` d
                unsafeWrite r i qq
                go (i - 1) rr
      remainder <- go (na - 1) 0
      frozen <- unsafeFreeze r
      return (frozen :: UArray Int Word, remainder)

-- | Truncating division with remainder (Knuth's Algorithm D).  Returns
-- 'Nothing' when the divisor is zero.
quotRemMag :: Mag -> Mag -> Maybe (Mag, Mag)
quotRemMag a b
  | isZeroMag b = Nothing
  | compareMag a b == LT = Just (zeroMag, a)
  | nb == 1 = let (q, r) = quotRemSmall a (limb b 0) in Just (q, fromWord r)
  | otherwise = Just (knuthD a b)
  where nb = limbCount b

knuthD :: Mag -> Mag -> (Mag, Mag)
knuthD a b = (trim qArr, remainder)
  where
    na = limbCount a
    nb = limbCount b            -- >= 2
    m = na - nb                 -- quotient has m+1 limbs
    -- D1: normalise so that the top limb of the divisor is >= base/2.
    d = base `quot` (limb b (nb - 1) + 1)
    vN = if d == 1 then b else mulSmall b d
    uN0 = if d == 1 then a else mulSmall a d
    vTop = limb vN (nb - 1)
    vSec = limb vN (nb - 2)

    (qArr, uArr) = runST $ do
      -- The normalised dividend occupies na+1 limbs.
      u <- newArray (0, na) 0 :: ST s (STUArray s Int Word)
      forM_ [0 .. limbCount uN0 - 1] $ \i -> unsafeWrite u i (limb uN0 i)
      q <- newArray (0, m) 0 :: ST s (STUArray s Int Word)
      forM_ [m, m - 1 .. 0] $ \j -> do
        -- D3: estimate the quotient limb from the top two limbs.
        u2 <- unsafeRead u (j + nb)
        u1 <- unsafeRead u (j + nb - 1)
        u0 <- unsafeRead u (j + nb - 2)
        let num = u2 * base + u1
            fix !qh !rh
              | qh >= base || qh * vSec > rh * base + u0 =
                  let rh' = rh + vTop
                  in if rh' < base then fix (qh - 1) rh' else qh - 1
              | otherwise = qh
            qhat = fix (num `quot` vTop) (num `rem` vTop)
        -- D4: multiply and subtract.
        let mulSub !i !carry !borrow
              | i >= nb = return (carry, borrow)
              | otherwise = do
                  let (c', pl) = (qhat * limb vN i + carry) `quotRem` base
                  x <- unsafeRead u (i + j)
                  let y = pl + borrow
                  if x >= y
                    then unsafeWrite u (i + j) (x - y) >> mulSub (i + 1) c' 0
                    else unsafeWrite u (i + j) (x + base - y) >> mulSub (i + 1) c' 1
        (carry, borrow) <- mulSub 0 0 0
        top <- unsafeRead u (j + nb)
        let sub = carry + borrow
        if top >= sub
          then unsafeWrite u (j + nb) (top - sub) >> unsafeWrite q j qhat
          else do
            -- D6: qhat was one too large; add the divisor back.  The final
            -- carry cancels the borrow out of the top limb.
            let addBack !i !c
                  | i >= nb = return c
                  | otherwise = do
                      x <- unsafeRead u (i + j)
                      let s = x + limb vN i + c
                      if s >= base
                        then unsafeWrite u (i + j) (s - base) >> addBack (i + 1) 1
                        else unsafeWrite u (i + j) s >> addBack (i + 1) 0
            c <- addBack 0 0
            unsafeWrite u (j + nb) ((top + base - sub + c) `rem` base)
            unsafeWrite q j (qhat - 1)
      qf <- unsafeFreeze q
      uf <- unsafeFreeze u
      return (qf :: UArray Int Word, uf :: UArray Int Word)

    -- D8: the remainder is the low nb limbs of u, divided by d.
    remainder =
      let rMag = trim (listArray (0, nb - 1) [unsafeAt uArr i | i <- [0 .. nb - 1]])
      in if d == 1 then rMag else fst (quotRemSmall rMag d)

-- | @powMag a e@ is @a@ raised to the power @e@, by left-to-right binary
-- exponentiation (@0^0 = 1@).  Squarings dominate; the extra multiplication
-- by @a@ at each set bit is cheap when @a@ is small.
powMag :: Mag -> Word -> Mag
powMag a e
  | e == 0 = oneMag
  | otherwise = go (finiteBitSize e - 2 - countLeadingZeros e) a
  where
    go !i !acc
      | i < 0 = acc
      | otherwise =
          let sq = mulMag acc acc
          in go (i - 1) (if testBit e i then mulMag sq a else sq)

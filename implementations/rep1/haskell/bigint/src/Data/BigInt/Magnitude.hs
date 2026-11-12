{-# LANGUAGE BangPatterns, FlexibleContexts #-}
-- |
-- Module      : Data.BigInt.Magnitude
-- Description : Unsigned arbitrary-precision integers (the engine room).
--
-- A 'Magnitude' is a non-negative integer stored as a little-endian array of
-- /limbs/ in base 'limbBase' = 10^9.  A power-of-ten base keeps decimal
-- parsing and printing linear (see "Data.BigInt.Decimal"), and two limbs
-- multiplied together (plus carries) still fit comfortably in a 64-bit 'Int'.
--
-- Invariant: there are no high zero limbs, so zero is the empty array and
-- structural equality is numeric equality.
--
-- Algorithms:
--
--   * 'add', 'sub', 'compare': linear;
--   * 'mul': schoolbook, O(n·m);
--   * 'quotRem': Knuth's Algorithm D, O((n − m + 1)·m), quotient and
--     remainder together;
--   * 'pow': left-to-right binary exponentiation.
--
-- Only fixed-size machine integers are used for arithmetic.
module Data.BigInt.Magnitude
  ( Magnitude
  , limbBase
    -- * Construction and inspection
  , zero
  , one
  , isZero
  , isEven
  , fromInt
  , toInt
  , fromLimbs
  , toLimbs
    -- * Arithmetic
  , add
  , sub
  , mul
  , quotRem
  , pow
  ) where

import Prelude hiding (quotRem)

import Control.Monad (when)
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray, thaw)
import Data.Array.Unboxed (UArray, bounds, listArray)
import Data.Bits (countLeadingZeros, finiteBitSize, testBit)

-- | A non-negative integer of arbitrary size.
newtype Magnitude = Magnitude (UArray Int Int)
  deriving (Eq)

instance Ord Magnitude where
  compare = compareMag

instance Show Magnitude where
  showsPrec d m = showParen (d > 10) $ showString "fromLimbs " . shows (toLimbs m)

-- | The radix of the limb representation, @10^9@.
limbBase :: Int
limbBase = 1000000000

------------------------------------------------------------------------
-- Raw array helpers

len :: Magnitude -> Int
len (Magnitude a) = let (lo, hi) = bounds a in hi - lo + 1
{-# INLINE len #-}

at :: Magnitude -> Int -> Int
at (Magnitude a) = unsafeAt a
{-# INLINE at #-}

newInts :: Int -> ST s (STUArray s Int Int)
newInts n = newArray (0, n - 1) 0

asInts :: STUArray s Int Int -> ST s (STUArray s Int Int)
asInts = return

-- | Wrap a raw array, dropping high zero limbs.
trimmed :: UArray Int Int -> Magnitude
trimmed a = go n
  where
    n = let (lo, hi) = bounds a in hi - lo + 1
    go !k | k > 0 && unsafeAt a (k - 1) == 0 = go (k - 1)
          | k == n = Magnitude a
          | otherwise = Magnitude (listArray (0, k - 1) [unsafeAt a i | i <- [0 .. k - 1]])

------------------------------------------------------------------------
-- Construction and inspection

-- | Zero.
zero :: Magnitude
zero = Magnitude (listArray (0, -1) [])

-- | One.
one :: Magnitude
one = Magnitude (listArray (0, 0) [1])

-- | Is the value zero?
isZero :: Magnitude -> Bool
isZero m = len m == 0

-- | Is the value even?  (The base is even, so only the lowest limb matters.)
isEven :: Magnitude -> Bool
isEven m = len m == 0 || even (at m 0)

-- | Convert a non-negative machine integer.  Negative input is clamped to
-- zero.
fromInt :: Int -> Magnitude
fromInt n = fromLimbs (go n)
  where
    go k | k <= 0 = []
         | otherwise = k `rem` limbBase : go (k `quot` limbBase)

-- | Convert back to a machine integer, or 'Nothing' if the value exceeds
-- 'maxBound'.
toInt :: Magnitude -> Maybe Int
toInt m = case len m of
  0 -> Just 0
  1 -> Just (at m 0)
  2 -> Just (at m 1 * limbBase + at m 0)
  3 | hi < 9 || (hi == 9 && lowPart <= maxBound - 9 * limbBase * limbBase) ->
        Just (hi * limbBase * limbBase + lowPart)
    where hi = at m 2
          lowPart = at m 1 * limbBase + at m 0
  _ -> Nothing

-- | Build from little-endian limbs, each of which must lie in
-- @[0, 'limbBase')@.  High zero limbs are dropped.
fromLimbs :: [Int] -> Magnitude
fromLimbs ls = trimmed (listArray (0, length ls - 1) ls)

-- | The little-endian limbs (no high zero limbs; empty for zero).
toLimbs :: Magnitude -> [Int]
toLimbs m = [at m i | i <- [0 .. len m - 1]]

------------------------------------------------------------------------
-- Comparison

compareMag :: Magnitude -> Magnitude -> Ordering
compareMag a b = case compare la lb of
  EQ -> go (la - 1)
  o -> o
  where
    la = len a
    lb = len b
    go !i | i < 0 = EQ
          | x /= y = compare x y
          | otherwise = go (i - 1)
      where x = at a i
            y = at b i

------------------------------------------------------------------------
-- Addition and subtraction

-- | Sum, O(n + m).
add :: Magnitude -> Magnitude -> Magnitude
add a b = trimmed $ runSTUArray $ do
  r <- newArray (0, n) 0
  let go !i !carry
        | i == n = unsafeWrite r n carry
        | otherwise = do
            let s = (if i < la then at a i else 0) + (if i < lb then at b i else 0) + carry
            if s >= limbBase
              then unsafeWrite r i (s - limbBase) >> go (i + 1) 1
              else unsafeWrite r i s >> go (i + 1) 0
  go 0 0
  return r
  where
    la = len a
    lb = len b
    n = max la lb

-- | Difference @a - b@, O(n).  Requires @a >= b@; otherwise the result is
-- unspecified.
sub :: Magnitude -> Magnitude -> Magnitude
sub a b = trimmed $ runSTUArray $ do
  r <- newArray (0, max 0 la - 1) 0
  let go !i !borrow
        | i == la = return ()
        | otherwise = do
            let d = at a i - (if i < lb then at b i else 0) - borrow
            if d < 0
              then unsafeWrite r i (d + limbBase) >> go (i + 1) 1
              else unsafeWrite r i d >> go (i + 1) 0
  go 0 0
  return r
  where
    la = len a
    lb = len b

------------------------------------------------------------------------
-- Multiplication

-- | Product by schoolbook long multiplication, O(n·m).
mul :: Magnitude -> Magnitude -> Magnitude
mul x y
  | isZero x || isZero y = zero
  | otherwise = trimmed $ runSTUArray $ do
      r <- newArray (0, la + lb - 1) 0
      let outer !i
            | i == lb = return ()
            | otherwise = do
                let !bi = at b i
                when (bi /= 0) $ inner i bi 0 0
                outer (i + 1)
          -- r[i+la] has not been written by earlier rows, so the final
          -- carry is stored rather than added.
          inner !i !bi !j !carry
            | j == la = unsafeWrite r (i + la) carry
            | otherwise = do
                v <- unsafeRead r (i + j)
                let t = v + at a j * bi + carry
                    q = t `quot` limbBase
                unsafeWrite r (i + j) (t - q * limbBase)
                inner i bi (j + 1) q
      outer 0
      return r
  where
    -- Keep the longer operand in the inner loop.
    (a, b) = if len x >= len y then (x, y) else (y, x)
    la = len a
    lb = len b

------------------------------------------------------------------------
-- Division

-- | Divide by a single limb (@0 < d < limbBase@): quotient and remainder.
divSmall :: Magnitude -> Int -> (Magnitude, Int)
divSmall a d = (trimmed q, rm)
  where
    n = len a
    (q, rm) = runST $ do
      out <- newInts n
      let go !i !r
            | i < 0 = return r
            | otherwise = do
                let cur = r * limbBase + at a i
                    qd = cur `quot` d
                unsafeWrite out i qd
                go (i - 1) (cur - qd * d)
      r' <- go (n - 1) 0
      frozen <- unsafeFreeze out
      return (frozen :: UArray Int Int, r')

-- | Multiply by a single limb into a raw array of the given length (which
-- must be @len a@ or @len a + 1@, and large enough for the product).
scaled :: Int -> Magnitude -> Int -> UArray Int Int
scaled k a size = runSTUArray $ do
  r <- newArray (0, size - 1) 0
  let go !i !carry
        | i == len a = when (i < size) (unsafeWrite r i carry)
        | otherwise = do
            let t = at a i * k + carry
                q = t `quot` limbBase
            unsafeWrite r i (t - q * limbBase)
            go (i + 1) q
  go 0 0
  return r

-- | Quotient and remainder, truncating (for non-negative operands this is
-- the usual division).  'Nothing' if the divisor is zero.
--
-- Uses Knuth's Algorithm D: each quotient limb is estimated from the top
-- limbs of the running remainder and corrected at most twice, so the cost is
-- O((n − m + 1)·m).
quotRem :: Magnitude -> Magnitude -> Maybe (Magnitude, Magnitude)
quotRem u v
  | isZero v = Nothing
  | u < v = Just (zero, u)
  | n == 1 = let (q, r) = divSmall u (at v 0) in Just (q, fromInt r)
  | otherwise = Just (algorithmD u v)
  where
    n = len v

algorithmD :: Magnitude -> Magnitude -> (Magnitude, Magnitude)
algorithmD u v = (trimmed quo, remainder)
  where
    m = len u
    n = len v
    -- Normalise so the divisor's top limb is at least limbBase / 2.
    d = limbBase `quot` (at v (n - 1) + 1)
    vn = Magnitude (scaled d v n)
    vTop = at vn (n - 1)
    vNext = at vn (n - 2)
    (quo, remScaled) = runST $ do
      un <- thaw (scaled d u (m + 1)) >>= asInts
      q <- newInts (m - n + 1)
      let step !j
            | j < 0 = return ()
            | otherwise = do
                uHi <- unsafeRead un (j + n)
                uMid <- unsafeRead un (j + n - 1)
                uLo <- unsafeRead un (j + n - 2)
                let num = uHi * limbBase + uMid
                    qh0 = num `quot` vTop
                    qh = estimate qh0 (num - qh0 * vTop) uLo
                borrowed <- mulSub un j qh
                if borrowed
                  then addBack un j >> unsafeWrite q j (qh - 1)
                  else unsafeWrite q j qh
                step (j - 1)
      step (m - n)
      qf <- unsafeFreeze q
      rf <- unsafeFreeze un
      return (qf :: UArray Int Int, rf :: UArray Int Int)
    -- Correct the estimate using the divisor's second limb.
    estimate !qh !rh !uLo
      | qh >= limbBase || qh * vNext > rh * limbBase + uLo =
          let qh' = qh - 1
              rh' = rh + vTop
          in if rh' >= limbBase then qh' else estimate qh' rh' uLo
      | otherwise = qh
    -- Subtract qh * vn from un[j .. j+n]; True if the result went negative.
    mulSub :: STUArray s Int Int -> Int -> Int -> ST s Bool
    mulSub un j qh = go 0 0 0
      where
        go !i !carry !borrow
          | i == n = do
              top <- unsafeRead un (j + n)
              let t = top - carry - borrow
              if t < 0 then unsafeWrite un (j + n) (t + limbBase) >> return True
                       else unsafeWrite un (j + n) t >> return False
          | otherwise = do
              x <- unsafeRead un (i + j)
              let p = qh * at vn i + carry
                  pq = p `quot` limbBase
                  t = x - (p - pq * limbBase) - borrow
              if t < 0 then unsafeWrite un (i + j) (t + limbBase) >> go (i + 1) pq 1
                       else unsafeWrite un (i + j) t >> go (i + 1) pq 0
    -- The estimate was one too large: add the divisor back.
    addBack :: STUArray s Int Int -> Int -> ST s ()
    addBack un j = go 0 0
      where
        go !i !carry
          | i == n = do
              top <- unsafeRead un (j + n)
              unsafeWrite un (j + n) ((top + carry) `rem` limbBase)
          | otherwise = do
              x <- unsafeRead un (i + j)
              let s = x + at vn i + carry
              if s >= limbBase then unsafeWrite un (i + j) (s - limbBase) >> go (i + 1) 1
                               else unsafeWrite un (i + j) s >> go (i + 1) 0
    -- The remainder is the low n limbs of the working array, un-normalised.
    remainder = fst (divSmall (trimmed (listArray (0, n - 1) [unsafeAt remScaled i | i <- [0 .. n - 1]])) d)

------------------------------------------------------------------------
-- Exponentiation

-- | @pow a e@ is @a ^ e@ for @e >= 0@ by left-to-right binary
-- exponentiation (O(log e) multiplications).  A negative exponent is treated
-- as zero.
pow :: Magnitude -> Int -> Magnitude
pow a e
  | e <= 0 = one
  | otherwise = go (topBit - 1) a
  where
    topBit = finiteBitSize e - 1 - countLeadingZeros e
    go !i !acc
      | i < 0 = acc
      | otherwise =
          let sq = mul acc acc
          in go (i - 1) (if testBit e i then mul sq a else sq)

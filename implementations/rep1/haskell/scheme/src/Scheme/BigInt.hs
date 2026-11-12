{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Scheme.BigInt
-- Description : Arbitrary-precision signed integers, implemented from scratch.
--
-- A 'BigInt' is either a machine word ('Small') or a sign and a magnitude
-- ('Big') stored as little-endian base-2^32 limbs.  The representation is
-- canonical: a value that fits in an 'Int' is always 'Small', so structural
-- equality coincides with numeric equality.
--
-- The algorithms are the classical ones: schoolbook addition, subtraction
-- and multiplication, Knuth's Algorithm D (TAOCP vol. 2, 4.3.1) for
-- division, and repeated division by @10^9@ for decimal output.  No
-- arbitrary-precision type from any library is used.
module Scheme.BigInt
  ( BigInt
    -- * Construction and conversion
  , fromInt
  , toInt
  , fromDecimal
  , toDecimal
    -- * Arithmetic
  , add
  , sub
  , mul
  , neg
  , quotRem
  , quot
  , rem
    -- * Inspection
  , isZero
  , signum
  ) where

import Prelude hiding (quot, quotRem, rem, signum)
import qualified Prelude as P

import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray)
import Data.Array.Unboxed (UArray, bounds, listArray, elems)
import Data.Array.Unsafe (unsafeFreeze)
import Data.Bits (countLeadingZeros, shiftL, shiftR, xor, (.&.), (.|.))
import Data.Char (digitToInt, isDigit)
import Data.Int (Int64)
import Data.Word (Word32, Word64)

-- | An arbitrary-precision integer.
data BigInt
  = Small {-# UNPACK #-} !Int
    -- ^ Any value in the range of 'Int'.
  | Big !Bool !Mag
    -- ^ Negative flag and magnitude; only for values outside the range of 'Int'.

-- | Little-endian base-2^32 magnitude with no most-significant zero limbs.
type Mag = UArray Int Word32

instance Eq BigInt where
  Small a == Small b = a == b
  Big s a == Big t b = s == t && a == b
  _ == _ = False

instance Ord BigInt where
  compare (Small a) (Small b) = compare a b
  compare (Small _) (Big s _) = if s then GT else LT
  compare (Big s _) (Small _) = if s then LT else GT
  compare (Big s a) (Big t b) = case (s, t) of
    (False, True)  -> GT
    (True, False)  -> LT
    (False, False) -> magCmp a b
    (True, True)   -> magCmp b a

instance Show BigInt where
  show = toDecimal

------------------------------------------------------------------------
-- Magnitudes

magLen :: Mag -> Int
magLen m = let (lo, hi) = bounds m in hi - lo + 1
{-# INLINE magLen #-}

limb :: Mag -> Int -> Word64
limb m i = fromIntegral (unsafeAt m i)
{-# INLINE limb #-}

-- | Build a magnitude of @n@ limbs (initially zero), then strip leading zeros.
buildMag :: Int -> (forall s. STUArray s Int Word32 -> ST s ()) -> Mag
buildMag n body = trim (runSTUArray (do arr <- newArray (0, n - 1) 0; body arr; pure arr))

trim :: Mag -> Mag
trim m
  | n' == n = m
  | otherwise = listArray (0, n' - 1) (take n' (elems m))
  where
    n = magLen m
    n' = go n
    go k | k > 0 && unsafeAt m (k - 1) == 0 = go (k - 1)
         | otherwise = k

magCmp :: Mag -> Mag -> Ordering
magCmp a b
  | la /= lb = compare la lb
  | otherwise = go (la - 1)
  where
    la = magLen a
    lb = magLen b
    go i | i < 0 = EQ
         | otherwise = case compare (unsafeAt a i) (unsafeAt b i) of
             EQ -> go (i - 1)
             o -> o

magAdd :: Mag -> Mag -> Mag
magAdd a b = buildMag (n + 1) $ \r -> do
  let go !i !carry
        | i < n = do
            let s = (if i < la then limb a i else 0) + (if i < lb then limb b i else 0) + carry
            unsafeWrite r i (fromIntegral s)
            go (i + 1) (s `shiftR` 32)
        | otherwise = unsafeWrite r n (fromIntegral carry)
  go 0 0
  where
    la = magLen a
    lb = magLen b
    n = max la lb

-- | @magSub a b@ requires @a >= b@.
magSub :: Mag -> Mag -> Mag
magSub a b = buildMag la $ \r -> do
  let go !i !borrow
        | i < la = do
            let d = fromIntegral (limb a i) - (if i < lb then fromIntegral (limb b i) else 0) - borrow :: Int64
            unsafeWrite r i (fromIntegral d)
            go (i + 1) (if d < 0 then 1 else 0)
        | otherwise = pure ()
  go 0 (0 :: Int64)
  where
    la = magLen a
    lb = magLen b

-- | Schoolbook multiplication, O(n*m).
magMul :: Mag -> Mag -> Mag
magMul a b
  | la == 0 || lb == 0 = emptyMag
  | otherwise = buildMag (la + lb) $ \r ->
      let outer !i
            | i >= la = pure ()
            | otherwise = do
                let ai = limb a i
                    inner !j !carry
                      | j < lb = do
                          rij <- unsafeRead r (i + j)
                          let t = ai * limb b j + fromIntegral rij + carry
                          unsafeWrite r (i + j) (fromIntegral t)
                          inner (j + 1) (t `shiftR` 32)
                      | otherwise = unsafeWrite r (i + lb) (fromIntegral carry)
                inner 0 0
                outer (i + 1)
      in outer 0
  where
    la = magLen a
    lb = magLen b

emptyMag :: Mag
emptyMag = listArray (0, -1) []

-- | Divide by a single nonzero limb, returning quotient and remainder.
magDivSmall :: Mag -> Word32 -> (Mag, Word32)
magDivSmall a d = runST $ do
  r <- newArray (0, max 0 (n - 1)) 0 :: ST s (STUArray s Int Word32)
  let go !i !rm
        | i < 0 = pure rm
        | otherwise = do
            let cur = (rm `shiftL` 32) .|. limb a i
            unsafeWrite r i (fromIntegral (cur `P.quot` dd))
            go (i - 1) (cur `P.rem` dd)
  rm <- go (n - 1) 0
  frozen <- unsafeFreeze r
  pure (trim (if n == 0 then emptyMag else frozen), fromIntegral rm)
  where
    n = magLen a
    dd = fromIntegral d :: Word64

-- | Multiply by a small factor and add a small addend.
magMulAddSmall :: Mag -> Word32 -> Word32 -> Mag
magMulAddSmall a m c = buildMag (n + 1) $ \r ->
  let go !i !carry
        | i < n = do
            let t = limb a i * fromIntegral m + carry
            unsafeWrite r i (fromIntegral t)
            go (i + 1) (t `shiftR` 32)
        | otherwise = unsafeWrite r n (fromIntegral carry)
  in go 0 (fromIntegral c)
  where n = magLen a

-- | Knuth's Algorithm D.  Requires @magLen v >= 2@ and @magLen u >= magLen v@.
magDivKnuth :: Mag -> Mag -> (Mag, Mag)
magDivKnuth u v = runST $ do
  q <- newArray (0, m - n) 0 :: ST s (STUArray s Int Word32)
  un <- newArray (0, m) 0 :: ST s (STUArray s Int Word32)
  -- un = u << s (m + 1 limbs)
  let shiftU !i
        | i > m = pure ()
        | otherwise = do
            let hi = if i < m then limb u i `shiftL` s else 0
                lo = if i > 0 then limb u (i - 1) `shiftR` (32 - s) else 0
            unsafeWrite un i (fromIntegral (hi .|. lo))
            shiftU (i + 1)
  shiftU 0
  jloop q un (m - n)
  r <- newArray (0, n - 1) 0 :: ST s (STUArray s Int Word32)
  let unshift !i
        | i >= n = pure ()
        | otherwise = do
            lo <- unsafeRead un i
            hi <- unsafeRead un (i + 1)
            let w = (fromIntegral lo `shiftR` s) .|. (fromIntegral hi `shiftL` (32 - s)) :: Word64
            unsafeWrite r i (fromIntegral w)
            unshift (i + 1)
  unshift 0
  qf <- unsafeFreeze q
  rf <- unsafeFreeze r
  pure (trim qf, trim rf)
  where
    m = magLen u
    n = magLen v
    s = countLeadingZeros (unsafeAt v (n - 1)) :: Int
    -- vn = v << s (n limbs)
    vn :: Mag
    vn = buildMagRaw n $ \arr ->
      let go !i | i >= n = pure ()
                | otherwise = do
                    let hi = limb v i `shiftL` s
                        lo = if i > 0 then limb v (i - 1) `shiftR` (32 - s) else 0
                    unsafeWrite arr i (fromIntegral (hi .|. lo))
                    go (i + 1)
      in go 0
    vTop = limb vn (n - 1)
    vSecond = limb vn (n - 2)
    base = 0x100000000 :: Word64
    jloop :: STUArray s Int Word32 -> STUArray s Int Word32 -> Int -> ST s ()
    jloop q un = go
      where
        go !j
          | j < 0 = pure ()
          | otherwise = do
              ujn <- unsafeRead un (j + n)
              ujn1 <- unsafeRead un (j + n - 1)
              ujn2 <- unsafeRead un (j + n - 2)
              let num = (fromIntegral ujn `shiftL` 32) .|. fromIntegral ujn1 :: Word64
                  qhat0 = num `P.quot` vTop
                  rhat0 = num - qhat0 * vTop
                  fixup !qh !rh
                    | qh >= base || qh * vSecond > ((rh `shiftL` 32) .|. fromIntegral ujn2) =
                        let qh' = qh - 1
                            rh' = rh + vTop
                        in if rh' < base then fixup qh' rh' else qh'
                    | otherwise = qh
                  qhat = fixup qhat0 rhat0
                  mulSub !i !k
                    | i >= n = pure k
                    | otherwise = do
                        uij <- unsafeRead un (i + j)
                        let p = qhat * limb vn i
                            t = fromIntegral uij - k - fromIntegral (p .&. 0xFFFFFFFF) :: Int64
                        unsafeWrite un (i + j) (fromIntegral t)
                        mulSub (i + 1) (fromIntegral (p `shiftR` 32) - (t `shiftR` 32))
              k <- mulSub 0 (0 :: Int64)
              let t = fromIntegral ujn - k :: Int64
              unsafeWrite un (j + n) (fromIntegral t)
              if t < 0
                then do
                  unsafeWrite q j (fromIntegral (qhat - 1))
                  let addBack !i !c
                        | i >= n = pure c
                        | otherwise = do
                            uij <- unsafeRead un (i + j)
                            let t' = fromIntegral uij + limb vn i + c
                            unsafeWrite un (i + j) (fromIntegral t')
                            addBack (i + 1) (t' `shiftR` 32)
                  c <- addBack 0 0
                  top <- unsafeRead un (j + n)
                  unsafeWrite un (j + n) (top + fromIntegral c)
                else unsafeWrite q j (fromIntegral qhat)
              go (j - 1)

-- | Like 'buildMag' but without stripping (used for normalised divisors).
buildMagRaw :: Int -> (forall s. STUArray s Int Word32 -> ST s ()) -> Mag
buildMagRaw n body = runSTUArray (do arr <- newArray (0, n - 1) 0; body arr; pure arr)

-- | Quotient and remainder of magnitudes; the divisor must be nonzero.
magDivMod :: Mag -> Mag -> (Mag, Mag)
magDivMod u v
  | magCmp u v == LT = (emptyMag, u)
  | lv == 1 = let (q, r) = magDivSmall u (unsafeAt v 0) in (q, if r == 0 then emptyMag else listArray (0, 0) [r])
  | otherwise = magDivKnuth u v
  where lv = magLen v

------------------------------------------------------------------------
-- Conversion between Small / Big

-- | Sign and magnitude of an 'Int'.
fromIntMag :: Int -> (Bool, Mag)
fromIntMag x = (x < 0, wordMag w)
  where w = if x < 0 then negate (fromIntegral x) else fromIntegral x :: Word64

wordMag :: Word64 -> Mag
wordMag w
  | w == 0 = emptyMag
  | w < 0x100000000 = listArray (0, 0) [fromIntegral w]
  | otherwise = listArray (0, 1) [fromIntegral w, fromIntegral (w `shiftR` 32)]

-- | Sign and magnitude of any 'BigInt'.
toSignMag :: BigInt -> (Bool, Mag)
toSignMag (Small x) = fromIntMag x
toSignMag (Big s m) = (s, m)

-- | Canonicalise a sign and (trimmed) magnitude.
fromSignMag :: Bool -> Mag -> BigInt
fromSignMag s m
  | n == 0 = Small 0
  | n == 1 = Small (applySign (fromIntegral (unsafeAt m 0)))
  | n == 2 && (w < 0x8000000000000000 || (s && w == 0x8000000000000000)) =
      Small (applySign (fromIntegral w))
  | otherwise = Big s m
  where
    n = magLen m
    w = limb m 0 .|. (limb m 1 `shiftL` 32)
    applySign :: Int -> Int
    applySign x = if s then negate x else x

-- | Convert an 'Int'.
fromInt :: Int -> BigInt
fromInt = Small

-- | Convert back to an 'Int' if the value fits.
toInt :: BigInt -> Maybe Int
toInt (Small x) = Just x
toInt _ = Nothing

------------------------------------------------------------------------
-- Arithmetic

-- | Negation.
neg :: BigInt -> BigInt
neg (Small x)
  | x == minBound = fromSignMag False (wordMag 0x8000000000000000)
  | otherwise = Small (negate x)
neg (Big s m) = fromSignMag (not s) m

-- | Is the value zero?
isZero :: BigInt -> Bool
isZero (Small 0) = True
isZero _ = False

-- | Sign of the value: -1, 0 or 1.
signum :: BigInt -> Int
signum (Small x) = fromEnum (compare x 0) - 1
signum (Big s _) = if s then -1 else 1

-- | Addition.
add :: BigInt -> BigInt -> BigInt
add (Small a) (Small b)
  | (a `xor` r) .&. (b `xor` r) >= 0 = Small r
  where r = a + b
add x y = addSM (toSignMag x) (toSignMag y)

-- | Subtraction.
sub :: BigInt -> BigInt -> BigInt
sub (Small a) (Small b)
  | (a `xor` b) .&. (a `xor` r) >= 0 = Small r
  where r = a - b
sub x y = let (s, m) = toSignMag y in addSM (toSignMag x) (not s && not (magLen m == 0), m)

addSM :: (Bool, Mag) -> (Bool, Mag) -> BigInt
addSM (sa, a) (sb, b)
  | sa == sb = fromSignMag sa (magAdd a b)
  | otherwise = case magCmp a b of
      EQ -> Small 0
      GT -> fromSignMag sa (magSub a b)
      LT -> fromSignMag sb (magSub b a)

-- | Multiplication.
mul :: BigInt -> BigInt -> BigInt
mul (Small a) (Small b)
  | small a && small b = Small (a * b)
  where small x = x > -0x80000000 && x < 0x80000000
mul x y =
  let (sa, a) = toSignMag x
      (sb, b) = toSignMag y
  in fromSignMag (sa /= sb) (magMul a b)

-- | Truncating division: @quotRem a b = (q, r)@ with @a = q*b + r@,
-- @q@ rounded toward zero and @r@ having the sign of @a@.  'Nothing' when
-- the divisor is zero.
quotRem :: BigInt -> BigInt -> Maybe (BigInt, BigInt)
quotRem _ (Small 0) = Nothing
quotRem (Small a) (Small b)
  | not (a == minBound && b == -1) = Just (Small (P.quot a b), Small (P.rem a b))
quotRem x y =
  let (sa, a) = toSignMag x
      (sb, b) = toSignMag y
      (q, r) = magDivMod a b
  in Just (fromSignMag (sa /= sb) q, fromSignMag sa r)

-- | Truncating quotient; 'Nothing' on division by zero.
quot :: BigInt -> BigInt -> Maybe BigInt
quot a b = fst <$> quotRem a b

-- | Remainder with the sign of the dividend; 'Nothing' on division by zero.
rem :: BigInt -> BigInt -> Maybe BigInt
rem a b = snd <$> quotRem a b

------------------------------------------------------------------------
-- Decimal conversion

-- | Parse an optionally signed string of ASCII digits.  Returns 'Nothing'
-- for anything else (including the empty digit string).
fromDecimal :: String -> Maybe BigInt
fromDecimal str = case str of
  '-' : ds -> go True ds
  '+' : ds -> go False ds
  ds -> go False ds
  where
    go s ds
      | null ds || not (all isDigit ds) = Nothing
      | otherwise = Just (fromSignMag s (chunks emptyMag ds))
    chunks !acc [] = acc
    chunks !acc ds =
      let (c, rest) = splitAt 9 ds
          val = foldl (\a d -> a * 10 + fromIntegral (digitToInt d)) (0 :: Word32) c
          scale = 10 ^ length c :: Word32
      in chunks (magMulAddSmall acc scale val) rest

-- | Decimal representation with a @-@ prefix for negative values.
toDecimal :: BigInt -> String
toDecimal (Small x) = show x
toDecimal (Big s m) = (if s then ('-' :) else id) (concat (go m []))
  where
    go mag acc
      | magLen mag == 0 = acc
      | otherwise =
          let (q, r) = magDivSmall mag 1000000000
              str = show r
              padded = if magLen q == 0 then str else replicate (9 - length str) '0' ++ str
          in go q (padded : acc)

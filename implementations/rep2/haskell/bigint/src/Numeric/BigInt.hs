-- |
-- Module      : Numeric.BigInt
-- Description : Signed arbitrary-precision integers.
--
-- 'BigInt' is a sign together with a 'Mag'nitude held in base @10^9@.
-- Decimal conversion is linear, multiplication is schoolbook, division is
-- Knuth's Algorithm D and exponentiation is binary exponentiation.
--
-- > let Just a = parseBigInt (Data.ByteString.Char8.pack "123456789012345678901234567890")
-- > show (a * a)   -- "15241578753238836750495351562536198787501905199875019052100"
--
-- Division follows C semantics: 'quotRemBig' truncates toward zero and the
-- remainder takes the sign of the dividend.
module Numeric.BigInt
  ( BigInt
    -- * Construction and conversion
  , fromInt
  , toInt
  , parseBigInt
  , renderBigInt
    -- * Inspection
  , signumBig
  , isZeroBig
    -- * Arithmetic
  , addBig
  , subBig
  , mulBig
  , negateBig
  , absBig
  , quotRemBig
  , powBig
  ) where

import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit)
import Numeric.BigInt.Magnitude

-- | A signed integer.  Invariant: zero is always 'Pos' (there is no
-- negative zero).
data BigInt = BigInt !Bool !Mag
  -- ^ @BigInt isNegative magnitude@

mk :: Bool -> Mag -> BigInt
mk neg m = BigInt (neg && not (isZeroMag m)) m

instance Eq BigInt where
  BigInt s a == BigInt t b = s == t && a == b

instance Ord BigInt where
  compare (BigInt False a) (BigInt False b) = compareMag a b
  compare (BigInt True a) (BigInt True b) = compareMag b a
  compare (BigInt True _) (BigInt False _) = LT
  compare (BigInt False _) (BigInt True _) = GT

instance Show BigInt where
  showsPrec p x = showParen (p > 6 && signumBig x < 0) (showString (BC.unpack (renderBigInt x)))

instance Read BigInt where
  readsPrec _ str =
    let s = dropWhile (== ' ') str
        (sign, rest) = case s of ('-' : r) -> ("-", r); _ -> ("", s)
        (ds, rest') = span isDigit rest
    in case parseBigInt (BC.pack (sign ++ ds)) of
         Just v | not (null ds) -> [(v, rest')]
         _ -> []

-- | Arithmetic on 'BigInt'.  'fromInteger' reads the argument 64 bits at a
-- time, so it is only a boundary conversion for literals; all arithmetic is
-- performed by this library.
instance Num BigInt where
  (+) = addBig
  (-) = subBig
  (*) = mulBig
  negate = negateBig
  abs = absBig
  signum x = fromInt (signumBig x)
  fromInteger n
    | n < 0 = negateBig (fromInteger (negate n))
    | n == 0 = fromInt 0
    | otherwise =
        let hi = fromInteger (n `shiftR` 32)
            lo = fromInteger (n .&. 0xFFFFFFFF) :: Word
        in addBig (mulBig hi (fromInt 4294967296)) (mk False (fromWord lo))

-- | Convert from a machine integer.
fromInt :: Int -> BigInt
fromInt n
  | n < 0 = mk True (fromWord (negate (fromIntegral n)))
  | otherwise = mk False (fromWord (fromIntegral n))

-- | Convert to a machine integer if the value fits.
toInt :: BigInt -> Maybe Int
toInt (BigInt neg m) = do
  w <- toWordMaybe m
  if neg
    then if w <= fromIntegral (maxBound :: Int) + 1 then Just (negate (fromIntegral w)) else Nothing
    else if w <= fromIntegral (maxBound :: Int) then Just (fromIntegral w) else Nothing

-- | Parse an optionally signed (@-@) string of ASCII digits.  Leading zeros
-- and @-0@ are accepted.  Returns 'Nothing' for anything else (including the
-- empty string and a bare @-@).
parseBigInt :: B.ByteString -> Maybe BigInt
parseBigInt s = case B.uncons s of
  Just (45, ds) -> body True ds
  _ -> body False s
  where
    body neg ds
      | B.null ds || not (B.all (\c -> c >= 48 && c <= 57) ds) = Nothing
      | otherwise = Just (mk neg (fromDecimal ds))

-- | Canonical decimal rendering: no leading zeros, @-@ only for negative
-- values, zero is @0@.
renderBigInt :: BigInt -> B.ByteString
renderBigInt (BigInt neg m)
  | neg = B.cons 45 (toDecimal m)
  | otherwise = toDecimal m

-- | @-1@, @0@ or @1@.
signumBig :: BigInt -> Int
signumBig (BigInt neg m)
  | isZeroMag m = 0
  | neg = -1
  | otherwise = 1

isZeroBig :: BigInt -> Bool
isZeroBig (BigInt _ m) = isZeroMag m

negateBig :: BigInt -> BigInt
negateBig (BigInt neg m) = mk (not neg) m

absBig :: BigInt -> BigInt
absBig (BigInt _ m) = BigInt False m

addBig :: BigInt -> BigInt -> BigInt
addBig (BigInt sa a) (BigInt sb b)
  | sa == sb = mk sa (addMag a b)
  | otherwise = case compareMag a b of
      EQ -> mk False zeroMag
      GT -> mk sa (subMag a b)
      LT -> mk sb (subMag b a)

subBig :: BigInt -> BigInt -> BigInt
subBig a b = addBig a (negateBig b)

mulBig :: BigInt -> BigInt -> BigInt
mulBig (BigInt sa a) (BigInt sb b) = mk (sa /= sb) (mulMag a b)

-- | Truncating division: @quotRemBig a b = Just (q, r)@ with
-- @a == q*b + r@, @|r| < |b|@ and @r@ zero or of the sign of @a@.
-- 'Nothing' if @b@ is zero.
quotRemBig :: BigInt -> BigInt -> Maybe (BigInt, BigInt)
quotRemBig (BigInt sa a) (BigInt sb b) = do
  (q, r) <- quotRemMag a b
  Just (mk (sa /= sb) q, mk sa r)

-- | @powBig a e@ is @a^e@ (with @0^0 = 1@); 'Nothing' if @e@ is negative.
-- Bases @0@, @1@ and @-1@ are handled in constant time for any exponent;
-- for other bases the exponent must fit in a machine word (the result
-- could not be stored otherwise).
powBig :: BigInt -> BigInt -> Maybe BigInt
powBig (BigInt sa a) (BigInt se e)
  | se = Nothing
  | isZeroMag e = Just (mk False oneMag)
  | isZeroMag a = Just (mk False zeroMag)
  | a == oneMag = Just (mk (sa && odd' e) oneMag)
  | otherwise = case toWordMaybe e of
      Nothing -> error "Numeric.BigInt.powBig: exponent too large"
      Just w -> Just (mk (sa && odd w) (powMag a w))
  where
    odd' m = snd (quotRemSmall m 2) == 1

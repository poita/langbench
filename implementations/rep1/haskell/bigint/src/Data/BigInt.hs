-- |
-- Module      : Data.BigInt
-- Description : Signed arbitrary-precision integers.
--
-- A 'BigInt' is a sign plus a 'Magnitude'.  Everything is implemented from
-- scratch with fixed-size machine integers; no 'Integer' is involved.
--
-- The names 'quot', 'rem', 'negate', 'abs', 'signum' and 'compare'-style
-- helpers clash with the "Prelude", so import this module qualified:
--
-- > import qualified Data.BigInt as B
-- >
-- > let Just a = B.parse (BC.pack "-123456789012345678901234567890")
-- >     Just b = B.parse (BC.pack "987654321")
-- > B.render (B.mul a b)
--
-- There is deliberately no 'Num' instance: its @fromInteger@ would have to
-- consume an 'Integer'.  Use 'fromInt' or 'parse' to build values.
module Data.BigInt
  ( BigInt
    -- * Construction and conversion
  , zero
  , one
  , fromInt
  , toInt
  , parse
  , render
    -- * Inspection
  , signum
  , isZero
  , isNegative
    -- * Arithmetic
  , negate
  , abs
  , add
  , sub
  , mul
  , quotRem
  , quot
  , rem
  , pow
  ) where

import Prelude hiding (abs, negate, quot, quotRem, rem, signum)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC

import Data.BigInt.Decimal (parseMagnitude, renderMagnitude)
import qualified Data.BigInt.Magnitude as M

-- | A signed integer of arbitrary size.  Invariant: zero is never negative.
data BigInt = BigInt !Bool !M.Magnitude
  deriving (Eq)

instance Ord BigInt where
  compare (BigInt na a) (BigInt nb b) = case (na, nb) of
    (False, True) -> GT
    (True, False) -> LT
    (False, False) -> compare a b
    (True, True) -> compare b a

-- | Shows the canonical decimal form, parenthesised when negative and in an
-- argument position (like 'Integer').
instance Show BigInt where
  showsPrec d x = showParen (d > 6 && isNegative x) $ showString (BC.unpack (render x))

-- | Build from a sign flag and magnitude, normalising negative zero.
make :: Bool -> M.Magnitude -> BigInt
make neg m = BigInt (neg && not (M.isZero m)) m

-- | Zero.
zero :: BigInt
zero = BigInt False M.zero

-- | One.
one :: BigInt
one = BigInt False M.one

-- | Convert a machine integer (any 'Int', including 'minBound').
fromInt :: Int -> BigInt
fromInt n
  | n >= 0 = BigInt False (M.fromInt n)
  | otherwise = make True (M.add (M.fromInt (-(n + 1))) M.one)

-- | Convert to a machine integer, or 'Nothing' if out of range.
toInt :: BigInt -> Maybe Int
toInt (BigInt False m) = M.toInt m
toInt (BigInt True m) = case M.toInt m of
  Just x -> Just (-x)
  Nothing | m == M.add (M.fromInt maxBound) M.one -> Just minBound
          | otherwise -> Nothing

-- | Parse an optional @-@ followed by one or more digits.  Leading zeros and
-- negative zero are accepted.  Anything else (including @+@, spaces, and the
-- empty string) is 'Nothing'.
parse :: BS.ByteString -> Maybe BigInt
parse s = case BC.uncons s of
  Just ('-', rest) -> make True <$> parseMagnitude rest
  _ -> make False <$> parseMagnitude s

-- | Canonical decimal form: no leading zeros, a @-@ only for negative values.
render :: BigInt -> BS.ByteString
render (BigInt neg m)
  | neg = BC.cons '-' (renderMagnitude m)
  | otherwise = renderMagnitude m

-- | @-1@, @0@ or @1@.
signum :: BigInt -> Int
signum (BigInt neg m)
  | M.isZero m = 0
  | neg = -1
  | otherwise = 1

-- | Is the value zero?
isZero :: BigInt -> Bool
isZero (BigInt _ m) = M.isZero m

-- | Is the value strictly negative?
isNegative :: BigInt -> Bool
isNegative (BigInt neg _) = neg

-- | Additive inverse.
negate :: BigInt -> BigInt
negate (BigInt neg m) = make (not neg) m

-- | Absolute value.
abs :: BigInt -> BigInt
abs (BigInt _ m) = BigInt False m

-- | Sum.
add :: BigInt -> BigInt -> BigInt
add (BigInt na a) (BigInt nb b)
  | na == nb = make na (M.add a b)
  | otherwise = case compare a b of
      EQ -> zero
      GT -> make na (M.sub a b)
      LT -> make nb (M.sub b a)

-- | Difference.
sub :: BigInt -> BigInt -> BigInt
sub a b = add a (negate b)

-- | Product (schoolbook).
mul :: BigInt -> BigInt -> BigInt
mul (BigInt na a) (BigInt nb b) = make (na /= nb) (M.mul a b)

-- | Quotient (truncated toward zero) and remainder (sign of the dividend)
-- computed together, so that @a == q * b + r@.  'Nothing' if the divisor is
-- zero.
quotRem :: BigInt -> BigInt -> Maybe (BigInt, BigInt)
quotRem (BigInt na a) (BigInt nb b) = do
  (q, r) <- M.quotRem a b
  return (make (na /= nb) q, make na r)

-- | Truncating quotient; 'Nothing' if the divisor is zero.
quot :: BigInt -> BigInt -> Maybe BigInt
quot a b = fst <$> quotRem a b

-- | Remainder with the sign of the dividend; 'Nothing' if the divisor is zero.
rem :: BigInt -> BigInt -> Maybe BigInt
rem a b = snd <$> quotRem a b

-- | @pow a e@ is @a ^ e@ by binary exponentiation.
--
-- 'Nothing' for a negative exponent (the result would not be an integer) and
-- for an exponent too large to be useful: bases @0@, @1@ and @-1@ are
-- answered for any exponent, but any other base with an exponent beyond the
-- range of 'Int' would need more memory than exists.  @0 ^ 0 == 1@.
pow :: BigInt -> BigInt -> Maybe BigInt
pow a@(BigInt neg m) e@(BigInt en em)
  | en = Nothing
  | M.isZero em = Just one
  | M.isZero m = Just zero
  | m == M.one = Just (if neg && not (M.isEven em) then a else one)
  | otherwise = do
      k <- toInt e
      return (make (neg && odd k) (M.pow m k))

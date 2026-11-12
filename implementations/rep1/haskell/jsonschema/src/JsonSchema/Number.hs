{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : JsonSchema.Number
-- Description : Exact decimal numbers.
--
-- JSON numbers are kept as exact rationals of the form @mantissa * 10^exponent@.
-- Nothing here ever touches binary floating point, so @0.3@ really is a
-- multiple of @0.0001@ and @1e309@ is simply a big number.
--
-- Values are stored in a canonical form (no trailing zeros in the mantissa,
-- zero is @0 * 10^0@), which makes the derived 'Eq' instance coincide with
-- numeric equality and lets 'hashNumber' be consistent with it.
module JsonSchema.Number
  ( Number
  , mkNumber
  , mantissa
  , exponent10
  , fromInt
  , isInteger
  , isZero
  , signumNumber
  , isMultipleOf
  , compareInt
  , showNumber
  ) where

-- | An exact decimal: @mantissa * 10 ^ exponent@, always in canonical form.
data Number = Number !Integer !Int
  deriving (Eq)

instance Ord Number where
  compare a@(Number m1 e1) b@(Number m2 e2)
    | sa /= sb = compare sa sb
    | e1 == e2 = compare m1 m2
    | e1 > e2 = compare (m1 * pow10 (e1 - e2)) m2
    | otherwise = compare m1 (m2 * pow10 (e2 - e1))
    where
      sa = signumNumber a
      sb = signumNumber b

instance Show Number where
  show = showNumber

pow10 :: Int -> Integer
pow10 n = 10 ^ n

-- | Build a number from a mantissa and a decimal exponent, normalising it.
mkNumber :: Integer -> Int -> Number
mkNumber 0 _ = Number 0 0
mkNumber m e = go m e
  where
    go !x !k = case x `quotRem` 10 of
      (q, 0) -> go q (k + 1)
      _ -> Number x k

-- | The (canonical) mantissa.
mantissa :: Number -> Integer
mantissa (Number m _) = m

-- | The (canonical) base-10 exponent.
exponent10 :: Number -> Int
exponent10 (Number _ e) = e

-- | An 'Int' as a number.
fromInt :: Int -> Number
fromInt n = mkNumber (toInteger n) 0

-- | Does the number denote a whole number?  (@1.0@, @1e2@ and @-0@ do.)
isInteger :: Number -> Bool
isInteger (Number _ e) = e >= 0

isZero :: Number -> Bool
isZero (Number m _) = m == 0

signumNumber :: Number -> Int
signumNumber (Number m _) = fromInteger (signum m)

-- | @x \`isMultipleOf\` d@: is @x / d@ an integer, computed exactly?
-- A zero divisor is never a divisor of anything but zero.
isMultipleOf :: Number -> Number -> Bool
isMultipleOf (Number m1 e1) (Number m2 e2)
  | m1 == 0 = True
  | m2 == 0 = False
  | e1 >= e2 = (m1 * pow10 (e1 - e2)) `rem` m2 == 0
  | otherwise = m1 `rem` (m2 * pow10 (e2 - e1)) == 0

-- | Compare a number with an 'Int'.
compareInt :: Number -> Int -> Ordering
compareInt n i = compare n (fromInt i)

-- | Render in plain or scientific notation, always re-readable as JSON.
showNumber :: Number -> String
showNumber (Number m e)
  | m == 0 = "0"
  | e == 0 = show m
  | e > 0 && e <= 20 = show m ++ replicate e '0'
  | otherwise = show m ++ "e" ++ show e

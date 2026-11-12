-- | Exact number conversions shared by the lexer and the standard library:
-- decimal text to binary64 and binary64 to fixed-point text.
module Langvm.Number
  ( decimalToDouble
  , showFixed
  , showIntRadixText
  ) where

import Data.Char (intToDigit)
import Data.Ratio ((%))
import Numeric (showIntAtBase)

-- | The binary64 nearest @m * 10^e@ (ties to even), with overflow to infinity
-- and underflow to a subnormal or zero.
decimalToDouble :: Integer -> Integer -> Double
decimalToDouble m e
  | m == 0 = 0
  | magnitude > 400 = 1 / 0
  | magnitude < -400 = 0
  | e >= 0 = fromRational (fromInteger (m * 10 ^ e))
  | otherwise = fromRational (m % (10 ^ negate e))
  where
    magnitude = toInteger (length (show m)) + e

-- | @showFixed d x@ is @printf "%.*f" d x@ for a finite @x@: the exact value
-- rounded to @d@ places with ties to even.
showFixed :: Int -> Double -> String
showFixed d x = sign ++ body
  where
    neg = x < 0 || isNegativeZero x
    sign = if neg then "-" else ""
    (mant, ex) = decodeFloat (abs x)
    scaled = fromIntegral mant * 10 ^ d :: Integer
    n | ex >= 0 = scaled * 2 ^ ex
      | otherwise =
          let den = 2 ^ negate ex :: Integer
              (q, r) = scaled `quotRem` den
              twice = 2 * r
          in if twice > den || (twice == den && odd q) then q + 1 else q
    digits = show n
    padded = replicate (d + 1 - length digits) '0' ++ digits
    body | d == 0 = padded
         | otherwise =
             let (a, b) = splitAt (length padded - d) padded in a ++ "." ++ b

-- | Digits @0-9a-z@ of a non-negative number in the given radix.
showIntRadixText :: Int -> Integer -> String
showIntRadixText radix n = showIntAtBase (toInteger radix) intToDigit' n ""
  where
    intToDigit' i
      | i < 10 = intToDigit i
      | otherwise = toEnum (fromEnum 'a' + i - 10)

-- | Exact decimal-to-double conversion and shortest round-trip rendering.
module Jq.Number
  ( decimalToDouble
  , renderDouble
  , truncateToInt
  ) where

import Data.ByteString.Builder (Builder, char7, integerDec, string7)
import Data.Char (intToDigit)
import Numeric (floatToDigits)

-- | @decimalToDouble m e@ is the double nearest (ties to even) to @m * 10^e@,
-- for a non-negative mantissa @m@.
decimalToDouble :: Integer -> Int -> Double
decimalToDouble m e
  | m == 0 = 0
  | m < 2 ^ (53 :: Int) && e >= 0 && e <= 22 = fromInteger m * 10 ^^ e
  | m < 2 ^ (53 :: Int) && e < 0 && e >= -22 = fromInteger m / 10 ^ negate e
  | digitsLen + e > 330 = 1 / 0
  | digitsLen + e < -360 = 0
  | e >= 0 = fromRational (fromInteger (m * 10 ^ e))
  | otherwise = fromRational (toRational m / toRational (10 ^ negate e :: Integer))
  where
    digitsLen = length (show m)

-- | Truncate toward zero to an 'Int', clamping huge magnitudes and mapping
-- NaN to 0.
truncateToInt :: Double -> Int
truncateToInt d
  | isNaN d = 0
  | d >= 4.0e18 = 4000000000000000000
  | d <= -4.0e18 = -4000000000000000000
  | otherwise = truncate d

-- | Render a double the way jq prints it: integers without a decimal point,
-- other numbers in their shortest round-trip form.
renderDouble :: Double -> Builder
renderDouble x
  | isNaN x = string7 "null"
  | isInfinite x = string7 (if x > 0 then "1.7976931348623157e+308" else "-1.7976931348623157e+308")
  | x == 0 = string7 (if isNegativeZero x then "-0" else "0")
  | x < 0 = char7 '-' <> pos (negate x)
  | otherwise = pos x
  where
    pos v
      | v < 1e17 && v == fromInteger (truncate v) = integerDec (truncate v)
      | otherwise = string7 (shortest v)

shortest :: Double -> String
shortest v
  | e > 0 && e <= 17 =
      if n <= e
        then ds ++ replicate (e - n) '0'
        else take e ds ++ "." ++ drop e ds
  | e <= 0 && e > -4 = "0." ++ replicate (negate e) '0' ++ ds
  | otherwise = mant ++ "e" ++ sign ++ pad (show (abs ex))
  where
    (digits, e) = floatToDigits 10 v
    ds = map intToDigit digits
    n = length ds
    ex = e - 1
    mant = case ds of
      [d] -> [d]
      (d : rest) -> d : '.' : rest
      [] -> "0"
    sign = if ex < 0 then "-" else "+"
    pad s = if length s < 2 then '0' : s else s

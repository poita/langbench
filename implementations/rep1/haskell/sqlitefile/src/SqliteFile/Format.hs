-- | Rendering values the way the @sqlite3@ shell does (spec, Part 5).
module SqliteFile.Format
  ( formatReal
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B

-- | Format a finite double like C's @%.15g@, with @.0@ appended to a mantissa
-- that has no point, and zero (of either sign) printed as @0.0@.
--
-- The digits come from exact rational arithmetic, so the rounding is correct.
formatReal :: Double -> ByteString
formatReal d
  | d == 0 = B.pack "0.0"
  | isNaN d = B.pack "NaN"
  | isInfinite d = B.pack (if d > 0 then "Inf" else "-Inf")
  | otherwise = B.pack ((if d < 0 then "-" else "") ++ body)
  where
    x = toRational (abs d)
    e0 = decimalExponent x (floor (logBase 10 (abs d) :: Double))
    scaled = x / (10 ^^ (e0 - 14))
    n0 = round scaled :: Integer
    (n, e) = if n0 >= 10 ^ (15 :: Int) then (n0 `div` 10, e0 + 1) else (n0, e0)
    digits = show n -- exactly 15 digits
    body
      | e < -4 || e >= 15 =
          let (lead, rest) = splitAt 1 digits
              frac = dropTrailingZeros rest
              mant = lead ++ "." ++ (if null frac then "0" else frac)
              ex = abs e
           in mant ++ "e" ++ (if e < 0 then "-" else "+") ++ (if ex < 10 then "0" else "") ++ show ex
      | e >= 0 =
          let (ip, fp) = splitAt (e + 1) digits
              frac = dropTrailingZeros fp
           in ip ++ "." ++ (if null frac then "0" else frac)
      | otherwise = "0." ++ replicate (-e - 1) '0' ++ dropTrailingZeros digits

dropTrailingZeros :: String -> String
dropTrailingZeros = reverse . dropWhile (== '0') . reverse

-- | The exact decimal exponent e with 10^e <= x < 10^(e+1), starting from a
-- floating-point estimate.
decimalExponent :: Rational -> Int -> Int
decimalExponent x = go
  where
    go e
      | x < 10 ^^ e = go (e - 1)
      | x >= 10 ^^ (e + 1) = go (e + 1)
      | otherwise = e

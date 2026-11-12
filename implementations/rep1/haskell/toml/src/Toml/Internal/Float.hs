-- | Exact conversions between decimal text and IEEE-754 binary64.
--
-- Both directions use arbitrary-precision 'Rational' arithmetic, so they are
-- correctly rounded (round-half-to-even) without any floating-point library
-- support.
module Toml.Internal.Float
  ( formatFloat
  , decimalToDouble
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Render a double the way C's @printf("%.16e")@ does, except that NaN
-- (of either sign) is @nan@ and the infinities are @inf@ and @-inf@.
--
-- >>> formatFloat 3.1415
-- "3.1415000000000002e+00"
formatFloat :: Double -> Text
formatFloat d
  | isNaN d = T.pack "nan"
  | isInfinite d = T.pack (if d > 0 then "inf" else "-inf")
  | otherwise = T.pack (sign ++ body)
  where
    neg = d < 0 || isNegativeZero d
    sign = if neg then "-" else ""
    x = abs d
    body
      | x == 0 = "0.0000000000000000e+00"
      | otherwise =
          let (n, k) = significand17 x
              digits = show n
          in take 1 digits ++ "." ++ drop 1 digits ++ "e" ++ (if k < 0 then "-" else "+") ++ pad2 (show (abs k))
    pad2 s = if length s < 2 then '0' : s else s

-- | For a positive finite double return @(n, k)@ with @10^16 <= n < 10^17@
-- and @x ~ n * 10^(k-16)@, @n@ correctly rounded.
significand17 :: Double -> (Integer, Int)
significand17 x = finish (exactExponent (floor (logBase 10 x :: Double)))
  where
    r = toRational x
    pow10 :: Int -> Rational
    pow10 k = 10 ^^ k
    -- the k with 10^k <= x < 10^(k+1), found exactly
    exactExponent :: Int -> Int
    exactExponent k
      | r < pow10 k = exactExponent (k - 1)
      | r >= pow10 (k + 1) = exactExponent (k + 1)
      | otherwise = k
    scaled k = round (r / pow10 (k - 16)) :: Integer -- 'round' is half-even
    finish k =
      let n = scaled k
      in if n >= 10 ^ (17 :: Int) then (n `div` 10, k + 1) else (n, k)

-- | @decimalToDouble m e@ is the double nearest to @m * 10^e@ (@m >= 0@).
-- Overflow gives infinity and underflow gives zero.
decimalToDouble :: Integer -> Integer -> Double
decimalToDouble m e
  | m == 0 = 0
  | magnitude > 310 = 1 / 0
  | magnitude < -330 = 0
  | e >= 0 = fromRational (fromInteger (m * 10 ^ e))
  | otherwise = fromRational (toRational m / fromInteger (10 ^ negate e))
  where
    magnitude = fromIntegral (length (show m)) + e

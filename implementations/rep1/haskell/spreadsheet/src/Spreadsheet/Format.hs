-- |
-- Module      : Spreadsheet.Format
-- Description : Display of values, including an exact @%.10g@ formatter.
module Spreadsheet.Format
  ( formatNumber
  , renderValue
  ) where

import Data.List (dropWhileEnd)
import Data.Text (Text)
import qualified Data.Text as T

import Spreadsheet.Types

-- | Text form of a value: strings verbatim, errors as their code, numbers per
-- 'formatNumber'.
renderValue :: Value -> Text
renderValue (VNumber d) = formatNumber d
renderValue (VText t) = t
renderValue (VError e) = errorText e

-- | Display a (finite) number.
--
-- Zero is @0@; integral values below 1e15 in magnitude are printed in full;
-- everything else is printed exactly as C's @printf("%.10g")@, using exact
-- rational arithmetic so that rounding is correct (ties to even) regardless of
-- the platform.
--
-- >>> formatNumber (1/3)
-- "0.3333333333"
-- >>> formatNumber 1e20
-- "1e+20"
formatNumber :: Double -> Text
formatNumber v
  | isNaN v || isInfinite v = T.pack (show v)
  | v == 0 = T.singleton '0'
  | abs v < 1e15 && v == fromIntegral t = T.pack (show t)
  | otherwise = T.pack (formatG10 v)
  where
    t = truncate v :: Int

-- | @%.10g@ for a finite non-zero double.
formatG10 :: Double -> String
formatG10 v = sign ++ body
  where
    sign = if v < 0 then "-" else ""
    r = toRational (abs v)
    -- Decimal exponent of the unrounded value, found exactly.
    e0 = fixup (floor (logBase 10 (abs v) :: Double))
    fixup :: Int -> Int
    fixup x
      | r < 10 ^^ x = fixup (x - 1)
      | r >= 10 ^^ (x + 1) = fixup (x + 1)
      | otherwise = x
    -- Ten significant digits as an integer in [10^9, 10^10]; 'round' on a
    -- Rational breaks ties to even.
    n0 = round (r / 10 ^^ (e0 - 9)) :: Integer
    (n, e)
      | n0 >= 10 ^ (10 :: Int) = (n0 `div` 10, e0 + 1)
      | otherwise = (n0, e0)
    ds = dropWhileEnd (== '0') (show n)
    body
      | e < -4 || e >= 10 = scientific
      | e >= 0 = fixedPos
      | otherwise = "0." ++ replicate (negate e - 1) '0' ++ ds
    scientific =
      let mant = case ds of
            [d] -> [d]
            d : rest -> d : '.' : rest
            [] -> "0"
          ae = abs e
       in mant ++ "e" ++ (if e < 0 then "-" else "+") ++ (if ae < 10 then "0" else "") ++ show ae
    fixedPos =
      let padded = ds ++ replicate (e + 1 - length ds) '0'
          (ip, fp) = splitAt (e + 1) padded
       in if null fp then ip else ip ++ "." ++ fp

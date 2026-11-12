-- | Reading and printing of JSON numbers.
module Jq.Number
  ( scanNumber
  , mkDouble
  , numberBuilder
  , formatNumber
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import Data.ByteString (ByteString)
import Data.Char (intToDigit)
import Data.Word (Word8)
import Numeric (floatToDigits)

isDigit8 :: Word8 -> Bool
isDigit8 w = w >= 48 && w <= 57

-- | Scan a JSON number (@-?int frac? exp?@) starting at an offset; returns
-- the correctly-rounded double and the offset just past the number.
scanNumber :: ByteString -> Int -> Maybe (Double, Int)
scanNumber bs i0 =
  let n = B.length bs
      at i = if i < n then B.index bs i else 0
      neg = at i0 == 45
      i1 = if neg then i0 + 1 else i0
      i2 = digitsEnd i1
      digitsEnd i = if i < n && isDigit8 (B.index bs i) then digitsEnd (i + 1) else i
  in if i2 == i1 then Nothing else
     let intPart = B.take (i2 - i1) (B.drop i1 bs)
         -- leading zeros are not valid JSON ("007"), but a lone 0 is
         badLead = B.length intPart > 1 && B.head intPart == 48
         (fracPart, i3)
           | at i2 == 46 =
               let e = digitsEnd (i2 + 1)
               in if e == i2 + 1 then (Nothing, i2) else (Just (B.take (e - i2 - 1) (B.drop (i2 + 1) bs)), e)
           | otherwise = (Just B.empty, i2)
     in case fracPart of
          Nothing -> Nothing
          Just frac | badLead -> Nothing
                    | otherwise ->
            let hasExp = at i3 == 101 || at i3 == 69
                signPos = i3 + 1
                esign = at signPos
                eStart = if esign == 43 || esign == 45 then signPos + 1 else signPos
                eEnd = digitsEnd eStart
                expOk = eEnd > eStart
            in if hasExp && not expOk then Nothing else
               let (ex, iEnd)
                     | hasExp = (readInt (B.take (eEnd - eStart) (B.drop eStart bs)) * (if esign == 45 then -1 else 1), eEnd)
                     | otherwise = (0, i3)
                   mant = readInteger (B.append intPart frac)
               in Just (mkDouble neg mant (ex - B.length frac), iEnd)

readInt :: ByteString -> Int
readInt = B.foldl' (\a w -> if a > 100000000 then a else a * 10 + fromIntegral (w - 48)) 0

readInteger :: ByteString -> Integer
readInteger b
  | B.length b <= 18 = fromIntegral (B.foldl' (\a w -> a * 10 + fromIntegral (w - 48)) (0 :: Int) b)
  | otherwise = B.foldl' (\a w -> a * 10 + fromIntegral (w - 48)) 0 b

-- | @mkDouble neg m e@ is the double nearest to @(-1)^neg * m * 10^e@
-- (ties to even).
mkDouble :: Bool -> Integer -> Int -> Double
mkDouble neg m e = sign v
  where
    sign x = if neg then negate x else x
    v | m == 0 = 0
      | m < 9007199254740992 && e >= 0 && e <= 22 = fromIntegral m * 10 ^^ e
      | m < 9007199254740992 && e < 0 && e >= -22 = fromIntegral m / 10 ^ negate e
      | e > 400 = 1 / 0
      | e < -800 = 0
      | e >= 0 = fromRational (fromInteger (m * 10 ^ e))
      | otherwise = fromRational (fromInteger m / fromInteger (10 ^ negate e))

-- | Compact rendering: integers without a decimal point, other numbers in
-- the shortest form that round-trips.
numberBuilder :: Double -> BB.Builder
numberBuilder x
  | isIntegral && abs x < 1e17 =
      if x == 0 && isNegativeZero x then BB.string7 "-0"
      else BB.integerDec (truncate x)
  | otherwise = BB.string7 (formatNumber x)
  where isIntegral = x == fromInteger (truncate x)

-- | See 'numberBuilder'.
formatNumber :: Double -> String
formatNumber x
  | isNaN x = "null"
  | isInfinite x = if x > 0 then "1.7976931348623157e+308" else "-1.7976931348623157e+308"
  | x < 0 || isNegativeZero x = '-' : formatNumber (negate x)
  | x == 0 = "0"
  | otherwise =
      let (ds, e) = floatToDigits 10 x
          n = length ds
          digits = map intToDigit ds
      in if e > 17 || e < -4 then sci digits (e - 1)
         else if e <= 0 then "0." ++ replicate (negate e) '0' ++ digits
         else if e >= n then digits ++ replicate (e - n) '0'
         else take e digits ++ "." ++ drop e digits
  where
    sci (d : rest) ex =
      d : (if null rest then "" else '.' : rest) ++ "e" ++ (if ex < 0 then "-" else "+")
        ++ (let s = show (abs ex) in if length s < 2 then '0' : s else s)
    sci [] _ = "0"

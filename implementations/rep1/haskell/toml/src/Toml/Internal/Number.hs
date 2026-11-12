-- | Integer and float literals, kept as canonical text.
module Toml.Internal.Number
  ( parseNumber
  ) where

import Data.Char (isDigit, isHexDigit, digitToInt)
import qualified Data.Text as T

import Toml.Internal.Float (decimalToDouble, formatFloat)
import Toml.Value (ScalarType (..))

-- | Parse an integer or float literal (the whole token).  Integers come back
-- in decimal, floats in the 17-significant-digit form of 'formatFloat'.
parseNumber :: String -> Maybe (ScalarType, String)
parseNumber s = case s of
  "inf"  -> float "inf"
  "+inf" -> float "inf"
  "-inf" -> float "-inf"
  "nan"  -> float "nan"
  "+nan" -> float "nan"
  "-nan" -> float "nan"
  '0' : 'x' : r -> radix isHexDigit 16 r
  '0' : 'o' : r -> radix (`elem` ['0' .. '7']) 8 r
  '0' : 'b' : r -> radix (`elem` "01") 2 r
  _ -> let (neg, r) = splitSign s in decimal neg r
  where
    float = Just . (,) TFloat

splitSign :: String -> (Bool, String)
splitSign ('-' : r) = (True, r)
splitSign ('+' : r) = (False, r)
splitSign r = (False, r)

isD :: Char -> Bool
isD c = isDigit c && c < '\x80'

-- | One or more digits, single underscores allowed between digits.
digitsUS :: (Char -> Bool) -> String -> Maybe (String, String)
digitsUS p (c : cs) | p c = Just (go [c] cs)
  where
    go acc (x : xs) | p x = go (x : acc) xs
    go acc ('_' : x : xs) | p x = go (x : acc) xs
    go acc rest = (reverse acc, rest)
digitsUS _ _ = Nothing

inRange :: Integer -> Bool
inRange n = n >= negate (2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int)

radix :: (Char -> Bool) -> Integer -> String -> Maybe (ScalarType, String)
radix p base r = do
  (ds, rest) <- digitsUS p r
  if null rest && length ds <= 70
    then let n = foldl (\a c -> a * base + fromIntegral (digitToInt c)) 0 ds
         in if inRange n then Just (TInteger, show n) else Nothing
    else Nothing

decimal :: Bool -> String -> Maybe (ScalarType, String)
decimal neg r = do
  (ip, rest) <- case r of
    '0' : more -> Just ("0", more)
    c : _ | c >= '1' && c <= '9' -> digitsUS isD r
    _ -> Nothing
  case rest of
    [] -> do
      if length ip > 19 then Nothing else do
        let n = (if neg then negate else id) (read ip :: Integer)
        if inRange n then Just (TInteger, show n) else Nothing
    '.' : more -> do
      (fp, rest') <- digitsUS isD more
      ex <- case rest' of
        [] -> Just 0
        _ -> expo rest'
      Just (mkFloat ip fp ex)
    _ -> do
      ex <- expo rest
      Just (mkFloat ip "" ex)
  where
    expo (e : more) | e == 'e' || e == 'E' = do
      let (eneg, more') = splitSign more
      (ds, rest) <- digitsUS isD more'
      if null rest then Just ((if eneg then negate else id) (clampExp ds)) else Nothing
    expo _ = Nothing
    clampExp ds = if length ds > 9 then 999999999 else read ds :: Integer
    mkFloat ip fp ex =
      let m = read (ip ++ fp) :: Integer
          d = decimalToDouble m (ex - fromIntegral (length fp))
      in (TFloat, T.unpack (formatFloat (if neg then negate d else d)))

-- | Textual validation and canonicalisation of TOML date-times.
--
-- No calendar library is involved: fields are checked and copied.
module Toml.Internal.DateTime
  ( parseDateTime
  , isDateShape
  , isTimeShape
  ) where

import Data.Char (isDigit)
import Toml.Value (ScalarType (..))

isD :: Char -> Bool
isD c = isDigit c && c < '\x80'

num :: String -> Int
num = foldl (\a c -> a * 10 + fromEnum c - 48) 0

-- | Does the token start like @YYYY-@ ?  (Used to pick a parser.)
isDateShape :: String -> Bool
isDateShape (a : b : c : d : '-' : _) = all isD [a, b, c, d]
isDateShape _ = False

-- | Does the token start like @HH:@ ?
isTimeShape :: String -> Bool
isTimeShape (a : b : ':' : _) = all isD [a, b]
isTimeShape _ = False

-- | Parse a whole token as one of the four date-time types, returning the
-- canonical text.  The date and time may be separated by @T@, @t@ (a space
-- must already have been replaced by the caller).
parseDateTime :: String -> Maybe (ScalarType, String)
parseDateTime s
  | isTimeShape s = do
      (t, rest) <- time s
      if null rest then Just (TTimeLocal, t) else Nothing
  | otherwise = do
      (d, rest) <- date s
      case rest of
        [] -> Just (TDateLocal, d)
        (c : r) | c == 'T' || c == 't' -> do
          (t, rest') <- time r
          case rest' of
            [] -> Just (TDateTimeLocal, d ++ "T" ++ t)
            _ -> do
              o <- offset rest'
              Just (TDateTime, d ++ "T" ++ t ++ o)
        _ -> Nothing

date :: String -> Maybe (String, String)
date (y1 : y2 : y3 : y4 : '-' : m1 : m2 : '-' : d1 : d2 : rest)
  | all isD [y1, y2, y3, y4, m1, m2, d1, d2]
  , year >= 1, month >= 1, month <= 12, day >= 1, day <= dim = Just ([y1, y2, y3, y4, '-', m1, m2, '-', d1, d2], rest)
  where
    year = num [y1, y2, y3, y4]
    month = num [m1, m2]
    day = num [d1, d2]
    dim | month == 2 = if leap then 29 else 28
        | month `elem` [4, 6, 9, 11] = 30
        | otherwise = 31 :: Int
    leap = year `mod` 4 == 0 && (year `mod` 100 /= 0 || year `mod` 400 == 0)
date _ = Nothing

-- | @HH:MM:SS[.frac]@, with trailing zeros of the fraction removed.
time :: String -> Maybe (String, String)
time (h1 : h2 : ':' : m1 : m2 : ':' : s1 : s2 : rest)
  | all isD [h1, h2, m1, m2, s1, s2]
  , num [h1, h2] <= 23, num [m1, m2] <= 59, num [s1, s2] <= 59 =
      let base = [h1, h2, ':', m1, m2, ':', s1, s2]
      in case rest of
           '.' : r ->
             let (ds, r') = span isD r
                 ds' = reverse (dropWhile (== '0') (reverse ds))
             in if null ds then Nothing
                else Just (base ++ (if null ds' then "" else '.' : ds'), r')
           _ -> Just (base, rest)
time _ = Nothing

offset :: String -> Maybe String
offset "Z" = Just "Z"
offset "z" = Just "Z"
offset [sg, h1, h2, ':', m1, m2]
  | sg == '+' || sg == '-'
  , all isD [h1, h2, m1, m2]
  , num [h1, h2] <= 23, num [m1, m2] <= 59 =
      if num [h1, h2, m1, m2] == 0 then Just "Z" else Just [sg, h1, h2, ':', m1, m2]
offset _ = Nothing


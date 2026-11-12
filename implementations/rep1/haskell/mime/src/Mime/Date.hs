-- | @Date@ header parsing and closed-form calendar arithmetic.
module Mime.Date
  ( ParsedDate (..)
  , parseDate
  , daysFromCivil
  , civilFromDays
  , formatUtc
  , formatOffset
  ) where

import Data.Char (isDigit)

import Mime.Lexical

-- | A successfully parsed date.
data ParsedDate = ParsedDate
  { dateEpoch :: Integer
  -- ^ seconds since 1970-01-01T00:00:00Z
  , dateOffset :: Int
  -- ^ zone offset in minutes
  }
  deriving (Eq, Show)

-- | Parse a raw @Date@ value; 'Nothing' when it is not a valid date.
parseDate :: String -> Maybe ParsedDate
parseDate raw = do
  let toks = tokens (stripComments raw)
      toks' = case toks of
        t : r | lowerAscii t `elem` ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] -> r
        _ -> toks
  (dayS, monS, yearS, timeS, zone) <- case toks' of
    a : b : c : d : r -> Just (a, b, c, d, case r of z : _ -> Just z; [] -> Nothing)
    _ -> Nothing
  day <- digits 1 2 dayS
  mon <- lookup (lowerAscii monS) (zip months [1 ..])
  year <- parseYear yearS
  (hh, mm, ss) <- parseTime timeS
  if day < 1 || day > 31 || year < 1 || year > 9999 || hh > 23 || mm > 59 || ss > 60
    then Nothing
    else Just ()
  if day > daysInMonth year mon then Nothing else Just ()
  let off = maybe 0 zoneOffset zone
      epoch =
        daysFromCivil year mon day * 86400 + toInteger (hh * 3600 + mm * 60 + ss)
          - toInteger off * 60
  Just (ParsedDate epoch off)
  where
    months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

stripComments :: String -> String
stripComments [] = []
stripComments ('(' : r) = stripComments (snd (skipComment r))
stripComments (c : r) = c : stripComments r

tokens :: String -> [String]
tokens s = case dropWhile sep s of
  [] -> []
  s' -> let (t, r) = break sep s' in t : tokens r
  where
    sep c = c == ' ' || c == '\t' || c == ','

digits :: Int -> Int -> String -> Maybe Int
digits lo hi s
  | n >= lo && n <= hi && all isDigit s = Just (read s)
  | otherwise = Nothing
  where
    n = length s

parseYear :: String -> Maybe Int
parseYear s = do
  y <- digits 2 4 s
  Just $ case length s of
    2 -> if y >= 50 then 1900 + y else 2000 + y
    3 -> 1900 + y
    _ -> y

parseTime :: String -> Maybe (Int, Int, Int)
parseTime s = case splitOn ':' s of
  [h, m] -> (,,) <$> digits 1 2 h <*> digits 1 2 m <*> pure 0
  [h, m, x] -> (,,) <$> digits 1 2 h <*> digits 1 2 m <*> digits 1 2 x
  _ -> Nothing
  where
    splitOn c str = case break (== c) str of
      (a, _ : r) -> a : splitOn c r
      (a, []) -> [a]

zoneOffset :: String -> Int
zoneOffset z = case z of
  sign : ds@[_, _, _, _] | sign `elem` "+-", all isDigit ds ->
    let v = read (take 2 ds) * 60 + read (drop 2 ds)
     in if sign == '-' then negate v else v
  _ -> maybe 0 id (lookup (lowerAscii z) names)
  where
    names =
      [ ("ut", 0), ("gmt", 0), ("z", 0), ("est", -300), ("edt", -240)
      , ("cst", -360), ("cdt", -300), ("mst", -420), ("mdt", -360)
      , ("pst", -480), ("pdt", -420) ]

isLeap :: Int -> Bool
isLeap y = (y `mod` 4 == 0 && y `mod` 100 /= 0) || y `mod` 400 == 0

daysInMonth :: Int -> Int -> Int
daysInMonth y m
  | m == 2 = if isLeap y then 29 else 28
  | m `elem` [4, 6, 9, 11] = 30
  | otherwise = 31

-- | Days from 1970-01-01 to the given proleptic Gregorian date.
daysFromCivil :: Int -> Int -> Int -> Integer
daysFromCivil y0 m d = toInteger (era * 146097 + doe - 719468)
  where
    y = if m <= 2 then y0 - 1 else y0
    era = y `div` 400
    yoe = y - era * 400
    mp = (m + 9) `mod` 12
    doy = (153 * mp + 2) `div` 5 + d - 1
    doe = yoe * 365 + yoe `div` 4 - yoe `div` 100 + doy

-- | Inverse of 'daysFromCivil': @(year, month, day)@.
civilFromDays :: Integer -> (Integer, Int, Int)
civilFromDays z0 = (if m <= 2 then y + 1 else y, fromInteger m, fromInteger d)
  where
    z = z0 + 719468
    era = z `div` 146097
    doe = z - era * 146097
    yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
    mp = (5 * doy + 2) `div` 153
    d = doy - (153 * mp + 2) `div` 5 + 1
    m = if mp < 10 then mp + 3 else mp - 9

pad :: Int -> Integer -> String
pad n v = let s = show v in replicate (n - length s) '0' ++ s

-- | Render an epoch as @YYYY-MM-DDTHH:MM:SSZ@ (UTC).
formatUtc :: Integer -> String
formatUtc epoch =
  pad 4 y ++ "-" ++ pad 2 (toInteger m) ++ "-" ++ pad 2 (toInteger d) ++ "T"
    ++ pad 2 (tod `div` 3600) ++ ":" ++ pad 2 (tod `mod` 3600 `div` 60) ++ ":"
    ++ pad 2 (tod `mod` 60) ++ "Z"
  where
    days = epoch `div` 86400
    tod = epoch - days * 86400
    (y, m, d) = civilFromDays days

-- | Render a zone offset in minutes as @±HHMM@ (more digits if needed).
formatOffset :: Int -> String
formatOffset off =
  (if off < 0 then '-' else '+') : pad 2 (toInteger (a `div` 60)) ++ pad 2 (toInteger (a `mod` 60))
  where
    a = abs off

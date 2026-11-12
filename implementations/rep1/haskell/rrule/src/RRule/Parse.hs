-- |
-- Module      : RRule.Parse
-- Description : Parsing of @RRULE@ values and date-times.
--
-- The parsers accept the grammar described in the project's specification:
-- upper-case names, @;@-separated parts, @,@-separated lists.  They are
-- strict about syntax (unknown parts, malformed numbers and bad dates are
-- errors) but do not check the cross-part restrictions of RFC 5545.
module RRule.Parse
  ( parseDateTime
  , parseRule
  , parseWeekday
  , splitOn
  ) where

import Data.Char (isDigit)
import RRule.Calendar (monthLength)
import RRule.Types

-- | Split a string on a separator character.  @splitOn ',' "a,b" == ["a","b"]@
-- and @splitOn ',' "" == [""]@.
splitOn :: Char -> String -> [String]
splitOn sep s = case break (== sep) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn sep rest

-- | Parse @YYYYMMDDTHHMMSS@, checking that the date and time exist.
--
-- >>> parseDateTime "19970902T090000"
-- Right (DateTime {dtYear = 1997, dtMonth = 9, dtDay = 2, dtHour = 9, dtMinute = 0, dtSecond = 0})
parseDateTime :: String -> Either String DateTime
parseDateTime s
  | length s /= 15 || s !! 8 /= 'T' || not (all isDigit (take 8 s ++ drop 9 s)) =
      Left ("malformed date-time: " ++ show s)
  | m < 1 || m > 12 || d < 1 || d > monthLength y m || hh > 23 || mi > 59 || ss > 59 =
      Left ("invalid date-time: " ++ show s)
  | otherwise = Right (DateTime y m d hh mi ss)
  where
    num a b = foldl' (\acc c -> acc * 10 + fromEnum c - 48) 0 (take (b - a) (drop a s)) :: Int
    y = num 0 4
    m = num 4 6
    d = num 6 8
    hh = num 9 11
    mi = num 11 13
    ss = num 13 15

-- | Parse a two-letter weekday code (@MO@ … @SU@).
parseWeekday :: String -> Either String Weekday
parseWeekday code = case lookup code table of
  Just w -> Right w
  Nothing -> Left ("unknown weekday: " ++ show code)
  where
    table = zip ["MO", "TU", "WE", "TH", "FR", "SA", "SU"] [minBound .. maxBound]

parseInt :: String -> Either String Int
parseInt s = case s of
  '-' : ds -> negate <$> unsigned ds
  _ -> unsigned s
  where
    unsigned ds
      | not (null ds) && all isDigit ds && length ds < 10 = Right (foldl' (\a c -> a * 10 + fromEnum c - 48) 0 ds)
      | otherwise = Left ("malformed integer: " ++ show s)

parseIntList :: String -> Either String [Int]
parseIntList = mapM parseInt . splitOn ','

parseByDay :: String -> Either String ByDay
parseByDay s = do
  let (num, code) = splitAt (length s - 2) s
  wd <- parseWeekday code
  ord' <- if null num then Right Nothing else Just <$> parseInt num
  Right (ByDay ord' wd)

parseFrequency :: String -> Either String Frequency
parseFrequency v = case v of
  "YEARLY" -> Right Yearly
  "MONTHLY" -> Right Monthly
  "WEEKLY" -> Right Weekly
  "DAILY" -> Right Daily
  _ -> Left ("unsupported FREQ: " ++ show v)

-- | Parse the value of an @RRULE@ (e.g. @"FREQ=MONTHLY;BYDAY=-1FR;COUNT=10"@).
-- @FREQ@ is required.
parseRule :: String -> Either String Rule
parseRule str = do
  parts <- mapM splitPart (splitOn ';' str)
  freqText <- maybe (Left "missing FREQ") Right (lookup "FREQ" parts)
  freq <- parseFrequency freqText
  foldl' (\acc p -> acc >>= apply p) (Right (defaultRule freq)) parts
  where
    splitPart p = case break (== '=') p of
      (k, '=' : v) | not (null k) -> Right (k, v)
      _ -> Left ("malformed rule part: " ++ show p)
    apply (k, v) r = case k of
      "FREQ" -> Right r
      "INTERVAL" -> (\n -> r {ruleInterval = n}) <$> parseInt v
      "COUNT" -> (\n -> r {ruleCount = Just n}) <$> parseInt v
      "UNTIL" -> (\t -> r {ruleUntil = Just t}) <$> parseDateTime v
      "WKST" -> (\w -> r {ruleWkst = w}) <$> parseWeekday v
      "BYMONTH" -> (\l -> r {ruleByMonth = l}) <$> parseIntList v
      "BYMONTHDAY" -> (\l -> r {ruleByMonthDay = l}) <$> parseIntList v
      "BYYEARDAY" -> (\l -> r {ruleByYearDay = l}) <$> parseIntList v
      "BYWEEKNO" -> (\l -> r {ruleByWeekNo = l}) <$> parseIntList v
      "BYSETPOS" -> (\l -> r {ruleBySetPos = l}) <$> parseIntList v
      "BYDAY" -> (\l -> r {ruleByDay = l}) <$> mapM parseByDay (splitOn ',' v)
      _ -> Left ("unsupported rule part: " ++ show k)

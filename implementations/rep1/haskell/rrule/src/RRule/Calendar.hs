-- |
-- Module      : RRule.Calendar
-- Description : Proleptic Gregorian calendar arithmetic on integer day numbers.
--
-- Dates are represented as plain 'Int' day numbers ('DayNumber'): day @0@ is
-- 1 January of year 1, which was a Monday in the proleptic Gregorian
-- calendar.  All conversions are closed-form (based on the 400-year cycle)
-- and run in constant time.  Nothing here depends on a date or calendar
-- library.
module RRule.Calendar
  ( DayNumber
  , isLeapYear
  , yearLength
  , monthLength
  , fromCivil
  , toCivil
  , weekdayIndex
  , WeekInfo (..)
  , weekInfo
  ) where

-- | Days since 0001-01-01 (day 0).  Negative values are valid.
type DayNumber = Int

-- | Gregorian leap-year rule.
isLeapYear :: Int -> Bool
isLeapYear y = y `rem` 4 == 0 && (y `rem` 100 /= 0 || y `rem` 400 == 0)
{-# INLINE isLeapYear #-}

-- | Number of days in a year (365 or 366).
yearLength :: Int -> Int
yearLength y = if isLeapYear y then 366 else 365
{-# INLINE yearLength #-}

-- | @monthLength year month@ is the number of days in a month (1-12).
monthLength :: Int -> Int -> Int
monthLength y m
  | m == 2 = if isLeapYear y then 29 else 28
  | m == 4 || m == 6 || m == 9 || m == 11 = 30
  | otherwise = 31
{-# INLINE monthLength #-}

-- | Day number of a calendar date @fromCivil year month day@.  The month
-- and day are assumed to be valid.
fromCivil :: Int -> Int -> Int -> DayNumber
fromCivil y m d = daysBeforeYear y + daysBeforeMonth y m + d - 1
{-# INLINE fromCivil #-}

-- Days from 0001-01-01 to the start of the given year.
daysBeforeYear :: Int -> Int
daysBeforeYear y = let p = y - 1 in 365 * p + p `div` 4 - p `div` 100 + p `div` 400
{-# INLINE daysBeforeYear #-}

-- Days from 1 January to the 1st of the month within a year.
daysBeforeMonth :: Int -> Int -> Int
daysBeforeMonth y m
  | m < 3 = 31 * (m - 1)
  | otherwise = (153 * (m - 3) + 2) `quot` 5 + 59 + (if isLeapYear y then 1 else 0)
{-# INLINE daysBeforeMonth #-}

-- | Inverse of 'fromCivil': @(year, month, day)@ of a day number.
toCivil :: DayNumber -> (Int, Int, Int)
toCivil n =
  let (q400, r0) = n `divMod` 146097
      c = min 3 (r0 `quot` 36524)
      r1 = r0 - 36524 * c
      q4 = r1 `quot` 1461
      r2 = r1 - 1461 * q4
      y1 = min 3 (r2 `quot` 365)
      yday = r2 - 365 * y1 -- 0-based day of the year
      year = 400 * q400 + 100 * c + 4 * q4 + y1 + 1
      leap = if isLeapYear year then 1 else 0
   in if yday < 31
        then (year, 1, yday + 1)
        else
          if yday < 59 + leap
            then (year, 2, yday - 30)
            else
              let t = yday - 59 - leap
                  m' = (5 * t + 2) `quot` 153
                  d = t - (153 * m' + 2) `quot` 5 + 1
               in (year, m' + 3, d)

-- | Weekday of a day number, Monday = 0 … Sunday = 6.
weekdayIndex :: DayNumber -> Int
weekdayIndex d = d `mod` 7
{-# INLINE weekdayIndex #-}

-- | Week-numbering data for one calendar year, for weeks starting on a given
-- weekday (see the @BYWEEKNO@ rules of the specification).
data WeekInfo = WeekInfo
  { wiStart :: !Int
  -- ^ @s(Y)@: 0-based day-of-year index of the first day of week 1 (may be
  -- negative: week 1 then starts in the previous December).
  , wiWeeks :: !Int
  -- ^ Number of weeks in the year (52 or 53).
  , wiPrev :: !Int
  -- ^ The week number given to the first days of January that precede week
  -- 1 (the last week of the previous year, as python-dateutil numbers it).
  }
  deriving (Eq, Show)

-- | @weekInfo wkst year@ where @wkst@ is the week-start weekday (Monday = 0).
weekInfo :: Int -> Int -> WeekInfo
weekInfo wkst y = WeekInfo s (weeksOf y s) prev
  where
    s = startOf y
    sPrev = startOf (y - 1)
    prev
      | sPrev < 0 = weeksOf (y - 1) sPrev
      | otherwise = 52 + (if (yearLength y - s) `mod` 7 >= 4 then 1 else 0)
    startOf yr =
      let first = (wkst - weekdayIndex (fromCivil yr 1 1)) `mod` 7
       in if first < 4 then first else first - 7
    weeksOf yr st =
      let l = yearLength yr - st
       in l `quot` 7 + (if l `rem` 7 >= 4 then 1 else 0)

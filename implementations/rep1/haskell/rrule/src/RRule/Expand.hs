{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : RRule.Expand
-- Description : Lazy expansion of a recurrence rule into occurrences.
--
-- The rule is evaluated period by period (a year, a month, a week or a day,
-- depending on the frequency).  Every candidate day of every period is tested
-- against every filter in constant time, @BYSETPOS@ then selects among the
-- days that were kept, and the result is emitted lazily.  No rule-specific
-- shortcuts are taken: a rule that can never match still visits every period
-- up to the end of year 9999.
module RRule.Expand
  ( occurrences
  , withDefaults
  , lastYear
  ) where

import Data.Array.Unboxed (UArray, accumArray, listArray, (!))
import Data.Bits (bit, complement, setBit, testBit, (.|.))
import qualified Data.IntSet as IntSet
import Data.Word (Word64)
import RRule.Calendar
import RRule.Types

-- | The last year for which periods are enumerated.
lastYear :: Int
lastYear = 9999

-- | Apply the defaults derived from DTSTART (specification step 1): when none
-- of @BYMONTHDAY@, @BYYEARDAY@, @BYWEEKNO@ and @BYDAY@ is given, a yearly rule
-- gets @BYMONTH@ (if absent) and @BYMONTHDAY@, a monthly rule gets
-- @BYMONTHDAY@ and a weekly rule gets @BYDAY@ from the start date.
withDefaults :: DateTime -> Rule -> Rule
withDefaults start r
  | not (null (ruleByMonthDay r) && null (ruleByYearDay r) && null (ruleByWeekNo r) && null (ruleByDay r)) = r
  | otherwise = case ruleFreq r of
      Yearly ->
        r
          { ruleByMonth = if null (ruleByMonth r) then [dtMonth start] else ruleByMonth r
          , ruleByMonthDay = [dtDay start]
          }
      Monthly -> r {ruleByMonthDay = [dtDay start]}
      Weekly -> r {ruleByDay = [ByDay Nothing (weekdayOf (fromCivil (dtYear start) (dtMonth start) (dtDay start)))]}
      Daily -> r
  where
    weekdayOf d = toEnum (weekdayIndex d)

-- | A rule compiled into constant-time membership tests.
data Plan = Plan
  { plFreq :: !Frequency
  , plInterval :: !Int
  , plWkst :: !Int
  , plMonths :: !Word64 -- bit m set: month m accepted
  , plMonthDaysPos :: !Word64 -- bit d set: day-of-month d accepted
  , plMonthDaysNeg :: !Word64 -- bit d set: day-of-month -d accepted
  , plYearDaysPos :: !(UArray Int Bool)
  , plYearDaysNeg :: !(UArray Int Bool)
  , plHasWeekNo :: !Bool
  , plWeekNoPos :: !Word64
  , plWeekNoNeg :: !Word64
  , plHasByDay :: !Bool
  , plPlainDays :: !Word64 -- bit w set: plain weekday code w
  , plOrdPos :: !(UArray Int Word64) -- per weekday: bit n set for ordinal n
  , plOrdNeg :: !(UArray Int Word64) -- per weekday: bit n set for ordinal -n
  , plOrdInYear :: !Bool -- ordinals count within the year, not the month
  , plSetPos :: [Int]
  }

allBits :: Word64
allBits = complement 0

-- | Mask with bit @|v|@ set for each value of the given sign (values outside
-- 1..63 in magnitude are ignored).
signedMask :: Bool -> [Int] -> Word64
signedMask positive = foldl' add 0
  where
    add m v
      | positive && v >= 1 && v <= 63 = setBit m v
      | not positive && v <= -1 && v >= -63 = setBit m (negate v)
      | otherwise = m

yearDayTable :: Bool -> [Int] -> UArray Int Bool
yearDayTable positive vs
  | null vs = listArray (0, 366) (repeat True)
  | otherwise = accumArray (\_ b -> b) False (0, 366) [(abs v, True) | v <- vs, abs v <= 366, (v > 0) == positive]

ordTable :: Bool -> [ByDay] -> UArray Int Word64
ordTable positive bds =
  accumArray
    (.|.)
    0
    (0, 6)
    [ (weekdayNumber w, bit (abs n))
    | ByDay (Just n) w <- bds
    , abs n <= 63
    , (n > 0) == positive
    ]

mkPlan :: Rule -> Plan
mkPlan r =
  Plan
    { plFreq = ruleFreq r
    , plInterval = ruleInterval r
    , plWkst = weekdayNumber (ruleWkst r)
    , plMonths = if null (ruleByMonth r) then allBits else foldl' (\m v -> if v >= 1 && v <= 12 then setBit m v else m) 0 (ruleByMonth r)
    , plMonthDaysPos = if null (ruleByMonthDay r) then allBits else signedMask True (ruleByMonthDay r)
    , plMonthDaysNeg = if null (ruleByMonthDay r) then allBits else signedMask False (ruleByMonthDay r)
    , plYearDaysPos = yearDayTable True (ruleByYearDay r)
    , plYearDaysNeg = yearDayTable False (ruleByYearDay r)
    , plHasWeekNo = not (null (ruleByWeekNo r))
    , plWeekNoPos = signedMask True (ruleByWeekNo r)
    , plWeekNoNeg = signedMask False (ruleByWeekNo r)
    , plHasByDay = not (null bds)
    , plPlainDays = foldl' setBit 0 [weekdayNumber w | ByDay Nothing w <- bds]
    , plOrdPos = ordTable True bds
    , plOrdNeg = ordTable False bds
    , plOrdInYear = ruleFreq r == Yearly && null (ruleByMonth r)
    , plSetPos = ruleBySetPos r
    }
  where
    bds = ruleByDay r

-- | One period: the half-open range of candidate day numbers @[lo, hi)@, and
-- the calendar year the period stands for (or @-1@ when it is not a single
-- year, i.e. for non-yearly periods).
data Period = Period
  { pLo :: !Int
  , pHi :: !Int
  , pYear :: !Int
  , pWeeks :: WeekInfo -- lazy: only computed when BYWEEKNO is used
  }

-- All periods in order, ending when the next period would start after 9999.
periods :: Plan -> DateTime -> [Period]
periods pl start = case plFreq pl of
  Yearly ->
    [ yearPeriod y
    | y <- takeWhile (<= lastYear) [dtYear start, dtYear start + step ..]
    ]
  Monthly ->
    [ let lo = fromCivil y m 1 in Period lo (lo + monthLength y m) (-1) undefined
    | mi <- takeWhile (\mi -> mi `div` 12 <= lastYear) [m0, m0 + step ..]
    , let (y, m0') = mi `divMod` 12
          m = m0' + 1
    ]
  Weekly ->
    let wd = weekdayIndex startDay
        a = startDay - (wd - plWkst pl) `mod` 7
        first = Period startDay (a + 7) (-1) undefined
        later = [Period s (s + 7) (-1) undefined | s <- [a + 7 * step, a + 14 * step ..]]
     in takeWhile ((<= lastDay) . pLo) (first : later)
  Daily ->
    [Period d (d + 1) (-1) undefined | d <- takeWhile (<= lastDay) [startDay, startDay + step ..]]
  where
    step = plInterval pl
    startDay = fromCivil (dtYear start) (dtMonth start) (dtDay start)
    m0 = dtYear start * 12 + dtMonth start - 1
    lastDay = fromCivil lastYear 12 31
    yearPeriod y =
      let lo = fromCivil y 1 1 in Period lo (lo + yearLength y) y (weekInfo (plWkst pl) y)

-- Does the day pass every filter?  Constant time.
passes :: Plan -> Period -> Int -> Bool
passes pl per d =
  testBit (plMonths pl) m
    && (testBit (plMonthDaysPos pl) dom || testBit (plMonthDaysNeg pl) (mlen - dom + 1))
    && (plYearDaysPos pl ! (yday + 1) || plYearDaysNeg pl ! (ylen - yday))
    && byDayOk
    && weekNoOk
  where
    (y, m, dom) = toCivil d
    ylen = yearLength y
    mlen = monthLength y m
    yday = d - fromCivil y 1 1 -- 0-based
    wd = weekdayIndex d
    byDayOk =
      not (plHasByDay pl)
        || testBit (plPlainDays pl) wd
        || ( if plOrdInYear pl
               then testBit (plOrdPos pl ! wd) (yday `quot` 7 + 1) || testBit (plOrdNeg pl ! wd) ((ylen - 1 - yday) `quot` 7 + 1)
               else testBit (plOrdPos pl ! wd) ((dom - 1) `quot` 7 + 1) || testBit (plOrdNeg pl ! wd) ((mlen - dom) `quot` 7 + 1)
           )
    weekNoOk = not (plHasWeekNo pl) || weekNoMatches
    weekNoMatches =
      let wi = if y == pYear per then pWeeks per else weekInfo (plWkst pl) y
          s = wiStart wi
          weeks = wiWeeks wi
          w = (yday - s) `quot` 7 + 1
          pos n = n >= 0 && n < 64 && testBit (plWeekNoPos pl) n
          neg n = n >= 0 && n < 64 && testBit (plWeekNoNeg pl) n
       in if yday < s
            then neg 1 || pos (wiPrev wi)
            else
              if w <= weeks
                then pos w || neg (weeks + 1 - w)
                else pos 1

-- Candidate days of a period that pass all the filters, in order.
keptDays :: Plan -> Period -> [Int]
keptDays pl per = go (pLo per)
  where
    hi = pHi per
    go !d
      | d >= hi = []
      | passes pl per d = d : go (d + 1)
      | otherwise = go (d + 1)

-- Apply BYSETPOS to the kept days of a period.
selectPositions :: [Int] -> [Int] -> [Int]
selectPositions ps days = map (arr !) (IntSet.toAscList idxs)
  where
    n = length days
    arr = listArray (0, n - 1) days :: UArray Int Int
    idxs = IntSet.fromList [i | p <- ps, let i = if p > 0 then p - 1 else n + p, i >= 0, i < n]

-- | @occurrences start rule@ is the lazy, chronologically ordered list of the
-- rule's occurrences for a series beginning at @start@.  It honours the
-- rule's @COUNT@ and @UNTIL@ (the list is finite then) and the end of year
-- 9999; apply 'take' for any other limit.
--
-- The rule's DTSTART defaults are applied with 'withDefaults'.  The input
-- is assumed to satisfy the restrictions of RFC 5545 (it is not validated).
occurrences :: DateTime -> Rule -> [DateTime]
occurrences start rule0 =
  maybe id take (ruleCount rule)
    . map toDateTime
    . maybe id (\u -> takeWhile (\d -> d * secsPerDay + startSecs <= u)) untilKey
    . dropWhile (< startDay)
    $ concatMap emit (maybe id (\u -> takeWhile (\p -> pLo p * secsPerDay + startSecs <= u)) untilKey (periods pl start))
  where
    rule = withDefaults start rule0
    pl = mkPlan rule
    secsPerDay = 86400
    startDay = fromCivil (dtYear start) (dtMonth start) (dtDay start)
    startSecs = dtHour start * 3600 + dtMinute start * 60 + dtSecond start
    untilKey = fmap (\u -> fromCivil (dtYear u) (dtMonth u) (dtDay u) * secsPerDay + dtHour u * 3600 + dtMinute u * 60 + dtSecond u) (ruleUntil rule)
    emit per
      | null (plSetPos pl) = keptDays pl per
      | otherwise = selectPositions (plSetPos pl) (keptDays pl per)
    toDateTime d =
      let (y, m, dd) = toCivil d
       in DateTime y m dd (dtHour start) (dtMinute start) (dtSecond start)

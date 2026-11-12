-- |
-- Module      : RRule
-- Description : Expansion of RFC 5545 recurrence rules.
--
-- A small library that expands @RRULE@ recurrence rules (@FREQ@ =
-- @YEARLY@, @MONTHLY@, @WEEKLY@ or @DAILY@ with @INTERVAL@, @COUNT@,
-- @UNTIL@, @WKST@, @BYMONTH@, @BYMONTHDAY@, @BYYEARDAY@, @BYWEEKNO@,
-- @BYDAY@ and @BYSETPOS@) into occurrences, with the semantics of
-- python-dateutil's @rrule@.  Dates are floating local date-times in the
-- proleptic Gregorian calendar.
--
-- > import RRule
-- >
-- > main :: IO ()
-- > main = do
-- >   let Right start = parseDateTime "19970902T090000"
-- >       Right rule  = parseRule "FREQ=MONTHLY;BYDAY=-1FR;COUNT=3"
-- >   mapM_ (putStrLn . formatDateTime) (occurrences start rule)
-- >   -- 19970926T090000
-- >   -- 19971031T090000
-- >   -- 19971128T090000
--
-- The sub-modules are re-exported here; see "RRule.Calendar" for the date
-- arithmetic and "RRule.Batch" for the line format of the command-line tool.
module RRule
  ( -- * Rules and dates
    module RRule.Types
    -- * Parsing and formatting
  , parseRule
  , parseDateTime
  , formatDateTime
    -- * Expansion
  , occurrences
  , withDefaults
  ) where

import RRule.Expand (occurrences, withDefaults)
import RRule.Format (formatDateTime)
import RRule.Parse (parseDateTime, parseRule)
import RRule.Types

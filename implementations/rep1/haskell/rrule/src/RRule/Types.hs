-- |
-- Module      : RRule.Types
-- Description : Data types describing a recurrence rule.
module RRule.Types
  ( Frequency (..)
  , Weekday (..)
  , weekdayNumber
  , ByDay (..)
  , DateTime (..)
  , Rule (..)
  , defaultRule
  ) where

-- | The supported recurrence frequencies.
data Frequency = Yearly | Monthly | Weekly | Daily
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | Days of the week.  The derived 'Enum' numbers them Monday = 0 … Sunday = 6.
data Weekday = Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | Weekday number, Monday = 0 … Sunday = 6.
weekdayNumber :: Weekday -> Int
weekdayNumber = fromEnum

-- | One element of a @BYDAY@ list: a weekday with an optional ordinal
-- (@2MO@ is @ByDay (Just 2) Monday@, @-1FR@ is @ByDay (Just (-1)) Friday@).
data ByDay = ByDay
  { byDayOrdinal :: Maybe Int
  , byDayWeekday :: Weekday
  }
  deriving (Eq, Ord, Show)

-- | A floating (time-zone free) date-time.  The derived 'Ord' instance is
-- chronological because the fields run from most to least significant.
data DateTime = DateTime
  { dtYear :: !Int
  , dtMonth :: !Int
  , dtDay :: !Int
  , dtHour :: !Int
  , dtMinute :: !Int
  , dtSecond :: !Int
  }
  deriving (Eq, Ord, Show)

-- | A recurrence rule.  An empty list means the corresponding @BY…@ part is
-- absent.
data Rule = Rule
  { ruleFreq :: Frequency
  , ruleInterval :: Int
  , ruleCount :: Maybe Int
  , ruleUntil :: Maybe DateTime
  , ruleWkst :: Weekday
  , ruleByMonth :: [Int]
  , ruleByMonthDay :: [Int]
  , ruleByYearDay :: [Int]
  , ruleByWeekNo :: [Int]
  , ruleByDay :: [ByDay]
  , ruleBySetPos :: [Int]
  }
  deriving (Eq, Show)

-- | A rule of the given frequency with every other part at its default
-- (interval 1, week start Monday, no @BY…@ parts, no limit).
defaultRule :: Frequency -> Rule
defaultRule f =
  Rule
    { ruleFreq = f
    , ruleInterval = 1
    , ruleCount = Nothing
    , ruleUntil = Nothing
    , ruleWkst = Monday
    , ruleByMonth = []
    , ruleByMonthDay = []
    , ruleByYearDay = []
    , ruleByWeekNo = []
    , ruleByDay = []
    , ruleBySetPos = []
    }

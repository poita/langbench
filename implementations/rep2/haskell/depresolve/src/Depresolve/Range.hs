-- |
-- Module      : Depresolve.Range
-- Description : Version ranges (@*@, exact, caret, tilde, comparators).
--
-- Every range denotes a half-open interval @[lower, upper)@ of versions (the
-- upper bound may be absent).  'satisfies' implements the semantics directly;
-- 'rangeInterval' gives the equivalent interval, which the resolver uses to
-- turn a range into a contiguous block of candidate indices.
module Depresolve.Range
  ( Range (..)
  , Comparator (..)
  , Op (..)
  , Interval (..)
  , satisfies
  , rangeInterval
  , inInterval
  , intervalIsEmpty
  ) where

import Depresolve.Version

-- | Comparison operator of a comparator.
data Op = Lt | Le | Gt | Ge
  deriving (Eq, Show)

-- | An operator together with its version, e.g. @>=1.2.0@.
data Comparator = Comparator !Op !Version
  deriving (Eq, Show)

-- | A version range.
data Range
  = Any                    -- ^ @*@
  | Exact !Version         -- ^ @X.Y.Z@
  | Caret !Version         -- ^ @^X.Y.Z@ (npm semantics)
  | Tilde !Version         -- ^ @~X.Y.Z@ (npm semantics)
  | Comparators [Comparator] -- ^ one to three comparators, all must hold
  deriving (Eq, Show)

-- | Half-open interval of versions: @lower <= v < upper@; 'Nothing' as upper
-- bound means unbounded.
data Interval = Interval
  { intervalLower :: !Version
  , intervalUpper :: !(Maybe Version)
  }
  deriving (Eq, Show)

-- | Does the version belong to the range?
--
-- >>> satisfies (Caret (Version 0 2 3)) (Version 0 2 9)
-- True
-- >>> satisfies (Caret (Version 0 0 3)) (Version 0 0 4)
-- False
satisfies :: Range -> Version -> Bool
satisfies Any _ = True
satisfies (Exact w) v = v == w
satisfies (Caret w) v = inInterval (rangeInterval (Caret w)) v
satisfies (Tilde w) v = inInterval (rangeInterval (Tilde w)) v
satisfies (Comparators cs) v = all ok cs
  where
    ok (Comparator Lt w) = v < w
    ok (Comparator Le w) = v <= w
    ok (Comparator Gt w) = v > w
    ok (Comparator Ge w) = v >= w

-- | The interval of versions a range accepts.
rangeInterval :: Range -> Interval
rangeInterval Any = Interval minVersion Nothing
rangeInterval (Exact v) = Interval v (Just (nextPatch v))
rangeInterval (Caret v@(Version x y z))
  | x > 0 = Interval v (Just (Version (x + 1) 0 0))
  | y > 0 = Interval v (Just (Version 0 (y + 1) 0))
  | otherwise = Interval v (Just (Version 0 0 (z + 1)))
rangeInterval (Tilde v@(Version x y _)) = Interval v (Just (Version x (y + 1) 0))
rangeInterval (Comparators cs) = foldr (intersect . single) (rangeInterval Any) cs
  where
    single (Comparator Lt w) = Interval minVersion (Just w)
    single (Comparator Le w) = Interval minVersion (Just (nextPatch w))
    single (Comparator Gt w) = Interval (nextPatch w) Nothing
    single (Comparator Ge w) = Interval w Nothing

minVersion :: Version
minVersion = Version 0 0 0

intersect :: Interval -> Interval -> Interval
intersect (Interval l1 u1) (Interval l2 u2) = Interval (max l1 l2) (minUpper u1 u2)
  where
    minUpper Nothing b = b
    minUpper a Nothing = a
    minUpper (Just a) (Just b) = Just (min a b)

-- | Membership in an interval.
inInterval :: Interval -> Version -> Bool
inInterval (Interval lo hi) v = v >= lo && maybe True (v <) hi

-- | True when no version lies in the interval.
intervalIsEmpty :: Interval -> Bool
intervalIsEmpty (Interval lo hi) = maybe False (<= lo) hi

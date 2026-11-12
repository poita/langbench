-- | Version ranges (@*@, exact, caret, tilde and comparator sets) and their
-- semantics.
module Depresolve.Range
  ( Range (..)
  , Comparator (..)
  , Op (..)
  , rangeInterval
  , satisfies
  , renderRange
  ) where

import Depresolve.Version

-- | A comparison operator.
data Op = Lt | Le | Gt | Ge
  deriving (Eq, Show)

-- | One comparator such as @>=1.2.0@.
data Comparator = Comparator !Op !Version
  deriving (Eq, Show)

-- | A version range.
data Range
  = Any                   -- ^ @*@
  | Exact !Version        -- ^ @X.Y.Z@
  | Caret !Version        -- ^ @^X.Y.Z@ (npm semantics)
  | Tilde !Version        -- ^ @~X.Y.Z@
  | Comparators [Comparator]
    -- ^ one or more comparators, all of which must hold
  deriving (Eq, Show)

-- | The range as a half-open interval @[lo, hi)@ of version keys. A range
-- that accepts nothing yields an interval with @lo >= hi@.
rangeInterval :: Range -> (VersionKey, VersionKey)
rangeInterval r = case r of
  Any -> (0, maxBound)
  Exact v -> let k = versionKey v in (k, k + 1)
  Caret (Version x y z)
    | x > 0 -> (keyBound x y z, keyBound (x + 1) 0 0)
    | y > 0 -> (keyBound x y z, keyBound 0 (y + 1) 0)
    | otherwise -> (keyBound x y z, keyBound 0 0 (z + 1))
  Tilde (Version x y z) -> (keyBound x y z, keyBound x (y + 1) 0)
  Comparators cs -> foldl step (0, maxBound) cs
  where
    step (lo, hi) (Comparator op v) =
      let k = versionKey v
       in case op of
            Lt -> (lo, min hi k)
            Le -> (lo, min hi (k + 1))
            Gt -> (max lo (k + 1), hi)
            Ge -> (max lo k, hi)

-- | Does the version satisfy the range?
satisfies :: Range -> Version -> Bool
satisfies r v = let (lo, hi) = rangeInterval r
                    k = versionKey v
                 in lo <= k && k < hi

-- | Render a range in the registry syntax.
renderRange :: Range -> String
renderRange r = case r of
  Any -> "*"
  Exact v -> renderVersion v
  Caret v -> '^' : renderVersion v
  Tilde v -> '~' : renderVersion v
  Comparators cs -> unwords [opS o ++ renderVersion v | Comparator o v <- cs]
  where
    opS Lt = "<"
    opS Le = "<="
    opS Gt = ">"
    opS Ge = ">="

-- |
-- Module      : Depresolve.Index
-- Description : Compile a 'Problem' into the dense form the search runs on.
--
-- Package names are interned to integers in ascending byte order of the name
-- (so id order is output order).  Each package's versions are sorted newest
-- first and stored in one flat array; every requirement's range is turned,
-- by binary search, into a contiguous half-open block @[lo, hi)@ of indices
-- into its target's newest-first version list.
module Depresolve.Index
  ( Index (..)
  , Req (..)
  , buildIndex
  , versionSlot
  ) where

import Data.Array
import Data.Array.Unboxed (UArray)
import qualified Data.Array.Unboxed as U
import qualified Data.Map.Strict as M
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)

import Depresolve.Range
import Depresolve.Types
import Depresolve.Version

-- | A compiled requirement: package id and the block @[reqLo, reqHi)@ of
-- candidate indices (0 = newest version of that package).
data Req = Req
  { reqPkg :: {-# UNPACK #-} !Int
  , reqLo :: {-# UNPACK #-} !Int
  , reqHi :: {-# UNPACK #-} !Int
  }
  deriving (Eq, Show)

-- | The compiled problem.
data Index = Index
  { ixNames :: !(Array Int Name)
    -- ^ package id to name, ascending byte order
  , ixOffsets :: !(UArray Int Int)
    -- ^ start of each package's versions in 'ixVersions' (length n+1)
  , ixVersions :: !(Array Int Version)
    -- ^ all versions, grouped by package, newest first within a package
  , ixDeps :: !(Array Int [Req])
    -- ^ compiled requirements of each version slot, in written order
  , ixRoot :: [Req]
    -- ^ compiled root requirements, in written order
  }

-- | Flat slot of the @i@-th newest version of package @p@.
versionSlot :: Index -> Int -> Int -> Int
versionSlot ix p i = ixOffsets ix U.! p + i
{-# INLINE versionSlot #-}

-- | Compile a problem.  Runs in O(input + R log V) plus the sorts.
buildIndex :: Problem -> Index
buildIndex (Problem registry root) =
  Index
    { ixNames = listArray (0, n - 1) (M.keys ids)
    , ixOffsets = offsets
    , ixVersions = listArray (0, total - 1) (map fst slots)
    , ixDeps = listArray (0, total - 1) (map (map compile . snd) slots)
    , ixRoot = map compile root
    }
  where
    reqNames = [reqName r | r <- root ++ concatMap pvRequirements registry]
    ids = M.fromList (zip (M.keys (M.fromList [(nm, ()) | nm <- map pvName registry ++ reqNames])) [0 :: Int ..])
    n = M.size ids
    pkgOf nm = ids M.! nm

    -- versions per package, newest first
    perPkg :: Array Int [(Version, [Requirement])]
    perPkg =
      fmap (sortBy (comparing (Down . fst)))
        (accumArray (flip (:)) [] (0, n - 1)
           [(pkgOf (pvName pv), (pvVersion pv, pvRequirements pv)) | pv <- registry])
    slots = concat (elems perPkg)
    total = length slots
    offsets = U.listArray (0, n) (scanl (+) 0 (map length (elems perPkg)))

    -- sorted version arrays used for the binary searches
    sortedVs :: Array Int (Array Int Version)
    sortedVs = fmap (\l -> listArray (0, length l - 1) (map fst l)) perPkg

    compile (Requirement nm rng) =
      let p = pkgOf nm
          vs = sortedVs ! p
          len = rangeSize (bounds vs)
          Interval lo hi = rangeInterval rng
          -- newest first: first index whose version is below the upper bound
          loIx = case hi of
            Nothing -> 0
            Just h -> firstIdx (< h) vs len
          -- first index whose version is below the lower bound
          hiIx = firstIdx (< lo) vs len
       in Req p loIx (max loIx hiIx)

-- | Smallest index @i@ in @[0,len]@ such that the predicate holds there (the
-- predicate must be monotone: False ... False True ... True); @len@ if never.
firstIdx :: (Version -> Bool) -> Array Int Version -> Int -> Int
firstIdx p vs len = go 0 len
  where
    go a b
      | a >= b = a
      | p (vs ! m) = go a m
      | otherwise = go (m + 1) b
      where m = (a + b) `div` 2

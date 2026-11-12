{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | The resolution search.
--
-- The search is the specified depth-first, newest-first, chronologically
-- backtracking procedure, run with an explicit stack of choice points so
-- that the depth (about 10,000 pending requirements on large inputs) costs
-- no call stack.
--
-- Representation:
--
-- * Package names are interned to dense integer ids; each package's versions
--   are stored newest first with order-preserving integer keys.
-- * Every requirement is precompiled to the contiguous index range
--   @[lo, hi)@ of candidates it admits (found by binary search once), so a
--   search step never scans versions.
-- * The pending requirements are an immutable list shared between choice
--   points; pushing a version's requirements conses onto it without copying
--   the rest.
-- * The chosen versions live in a mutable array. Because backtracking always
--   returns to the most recent choice point, undoing is just clearing the
--   slot of the package whose candidates are exhausted.
module Depresolve.Resolve
  ( resolve
  , Resolution
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array (Array, listArray, (!))
import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Array.Unboxed (UArray)
import qualified Data.Array.Unboxed as U
import Data.List (sortOn)
import qualified Data.Map.Strict as M

import Depresolve.Range (rangeInterval)
import Depresolve.Registry
import Depresolve.Version

-- | The chosen version of every needed package, sorted by name.
type Resolution = [(PackageName, Version)]

-- | A compiled requirement: package id, and the candidate index range
-- @[lo, hi)@ in that package's newest-first version list.
data CReq = CReq !Int !Int !Int

-- | A compiled package.
data Pkg = Pkg
  { pkgName :: PackageName
  , pkgVersions :: Array Int Version
  , pkgReqs :: Array Int [CReq]
  }

-- | A choice point: package, next untried candidate, end of the candidate
-- range, and the pending requirements that follow the package's own.
data Choice = Choice !Int !Int !Int [CReq]

-- | Resolve the root requirements against the registry. Returns the first
-- solution in the specified search order, or 'Nothing' if none exists.
resolve :: Registry -> [Requirement] -> Maybe Resolution
resolve reg root = runST (search nPkgs pkgs rootReqs)
  where
    entries = registryEntries reg
    allNames =
      [n | (n, _, _) <- entries]
        ++ [reqName r | (_, _, rs) <- entries, r <- rs]
        ++ map reqName root
    ids = M.fromList (zip (M.keys (M.fromList [(n, ()) | n <- allNames])) [0 ..])
    nPkgs = M.size ids
    idOf n = ids M.! n

    -- versions of each package, newest first
    byName = M.fromListWith (++) [(n, [(v, rs)]) | (n, v, rs) <- entries]
    keysOf :: M.Map PackageName (UArray Int Int)
    keysOf = M.mapWithKey (\_ vs -> mkKeys vs) byName

    mkKeys :: [(Version, [Requirement])] -> UArray Int Int
    mkKeys vs = U.listArray (0, length vs - 1) [versionKey v | (v, _) <- sortDesc vs]
    sortDesc = sortOn (negate . versionKey . fst)

    emptyKeys = U.listArray (0, -1) [] :: UArray Int Int

    compile (Requirement n r) =
      let ks = M.findWithDefault emptyKeys n keysOf
          (lo, hi) = rangeInterval r
          size = snd (U.bounds ks) + 1
       in CReq (idOf n) (firstBelow ks size hi) (firstBelow ks size lo)

    pkgs :: Array Int Pkg
    pkgs = listArray (0, nPkgs - 1) [mkPkg n | n <- M.keys ids]
    mkPkg n =
      let vs = sortDesc (M.findWithDefault [] n byName)
          k = length vs
       in Pkg
            { pkgName = n
            , pkgVersions = listArray (0, k - 1) (map fst vs)
            , pkgReqs = listArray (0, k - 1) [map compile rs | (_, rs) <- vs]
            }
    rootReqs = map compile root

-- | In a descending key array of the given size, the first index whose key is
-- below @t@ (that is, the number of keys @>= t@).
firstBelow :: UArray Int Int -> Int -> Int -> Int
firstBelow ks size t = go 0 size
  where
    go !l !h
      | l >= h = l
      | ks U.! m >= t = go (m + 1) h
      | otherwise = go l m
      where m = (l + h) `div` 2

search :: forall s. Int -> Array Int Pkg -> [CReq] -> ST s (Maybe Resolution)
search nPkgs pkgs rootReqs = do
  chosen <- newArray (0, max 0 (nPkgs - 1)) (-1) :: ST s (STUArray s Int Int)
  let -- Process the pending requirements.
      go :: [CReq] -> [Choice] -> ST s (Maybe Resolution)
      go [] _ = Just <$> collect chosen
      go (CReq p lo hi : rest) cps = do
        c <- readArray chosen p
        if c >= 0
          then if c >= lo && c < hi then go rest cps else backtrack cps
          else
            if lo >= hi
              then backtrack cps
              else do
                writeArray chosen p lo
                go (pkgReqs (pkgs ! p) ! lo `prepend` rest) (Choice p (lo + 1) hi rest : cps)
      -- Move the most recent choice point to its next candidate.
      backtrack :: [Choice] -> ST s (Maybe Resolution)
      backtrack [] = return Nothing
      backtrack (Choice p i hi rest : cps)
        | i < hi = do
            writeArray chosen p i
            go (pkgReqs (pkgs ! p) ! i `prepend` rest) (Choice p (i + 1) hi rest : cps)
        | otherwise = do
            writeArray chosen p (-1)
            backtrack cps
  go rootReqs []
  where
    prepend [] rest = rest
    prepend (x : xs) rest = x : prepend xs rest
    collect :: STUArray s Int Int -> ST s Resolution
    collect chosen = do
      xs <- mapM (\p -> do
                    c <- readArray chosen p
                    let pk = pkgs ! p
                    return [(pkgName pk, pkgVersions pk ! c) | c >= 0])
                 [0 .. nPkgs - 1]
      -- ids are assigned in ascending name order, so xs is already sorted
      return (concat xs)

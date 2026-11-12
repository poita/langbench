-- | QuickCheck generators for versions, ranges and small problems.
module Depresolve.Gen
  ( genVersion
  , genRange
  , genProblem
  ) where

import qualified Data.ByteString.Char8 as B
import Data.List (nubBy)
import Test.QuickCheck

import Depresolve

-- | Small components so that range boundaries are hit often.
genVersion :: Gen Version
genVersion = Version <$> c <*> c <*> c
  where c = frequency [(8, choose (0, 3)), (1, choose (0, 1000000))]

genRange :: Gen Range
genRange = oneof
  [ pure Any
  , Exact <$> genVersion
  , Caret <$> genVersion
  , Tilde <$> genVersion
  , Comparators <$> (choose (1, 3) >>= \k -> vectorOf k genComparator)
  ]
  where
    genComparator = Comparator <$> elements [Lt, Le, Gt, Ge] <*> genVersion

-- | A small random registry over packages @p0..p4@ (plus an unregistered
-- @ghost@), with possible cycles, and a random root.
genProblem :: Gen Problem
genProblem = do
  nPk <- choose (1, 5)
  let names = [B.pack ('p' : show i) | i <- [0 .. nPk - 1 :: Int]]
      target = frequency [(20, elements names), (1, pure (B.pack "ghost"))]
      reqs = do
        k <- choose (0, 3)
        ns <- vectorOf k target
        mapM (\n -> Requirement n <$> genRange) (nubBy (==) ns)
  pvs <- fmap concat . mapM (\n -> do
           vs <- listOf (Version <$> choose (0, 2) <*> choose (0, 2) <*> choose (0, 2))
           mapM (\v -> PackageVersion n v <$> reqs) (nubBy (==) vs)) $ names
  shuffled <- shuffle pvs
  Problem shuffled <$> reqs

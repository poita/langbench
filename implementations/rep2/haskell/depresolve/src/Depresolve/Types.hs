-- |
-- Module      : Depresolve.Types
-- Description : The input data model: registry entries, requirements, problems.
module Depresolve.Types
  ( Name
  , Requirement (..)
  , PackageVersion (..)
  , Problem (..)
  ) where

import Data.ByteString (ByteString)

import Depresolve.Range (Range)
import Depresolve.Version (Version)

-- | A package name (ASCII).
type Name = ByteString

-- | A dependency requirement: a package name and an acceptable range.
data Requirement = Requirement
  { reqName :: !Name
  , reqRange :: !Range
  }
  deriving (Eq, Show)

-- | One registry line: a version of a package and its requirements, in the
-- order written.
data PackageVersion = PackageVersion
  { pvName :: !Name
  , pvVersion :: !Version
  , pvRequirements :: [Requirement]
  }
  deriving (Eq, Show)

-- | A complete resolution problem: the registry (in any order) and the root
-- manifest's requirements (in the order written; order matters).
data Problem = Problem
  { problemRegistry :: [PackageVersion]
  , problemRoot :: [Requirement]
  }
  deriving (Eq, Show)

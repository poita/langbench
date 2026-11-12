-- | The package registry and requirement types.
module Depresolve.Registry
  ( PackageName
  , Requirement (..)
  , Registry
  , emptyRegistry
  , addVersion
  , fromEntries
  , packageNames
  , versionsOf
  , registryEntries
  ) where

import qualified Data.Map.Strict as M

import Depresolve.Range (Range)
import Depresolve.Version (Version)

-- | A package name (@[a-z][a-z0-9-]*@).
type PackageName = String

-- | A dependency of a package version (or of the root): a target package
-- and the range of its versions that is acceptable.
data Requirement = Requirement
  { reqName :: PackageName
  , reqRange :: Range
  }
  deriving (Eq, Show)

-- | Every version of every package, each with its requirements (in the order
-- they are to be processed).
newtype Registry = Registry (M.Map PackageName (M.Map Version [Requirement]))
  deriving (Eq, Show)

-- | A registry with no packages.
emptyRegistry :: Registry
emptyRegistry = Registry M.empty

-- | Declare a package version with its requirements. Re-declaring the same
-- name and version replaces the earlier declaration.
addVersion :: PackageName -> Version -> [Requirement] -> Registry -> Registry
addVersion n v rs (Registry m) =
  Registry (M.insertWith (const (M.insert v rs)) n (M.singleton v rs) m)

-- | Build a registry from @(name, version, requirements)@ entries in any order.
fromEntries :: [(PackageName, Version, [Requirement])] -> Registry
fromEntries = foldl (\r (n, v, rs) -> addVersion n v rs r) emptyRegistry

-- | Names of all packages having at least one version, ascending.
packageNames :: Registry -> [PackageName]
packageNames (Registry m) = M.keys m

-- | The versions of a package, oldest first, with their requirements.
versionsOf :: PackageName -> Registry -> [(Version, [Requirement])]
versionsOf n (Registry m) = maybe [] M.toAscList (M.lookup n m)

-- | All entries, ordered by name and then ascending version.
registryEntries :: Registry -> [(PackageName, Version, [Requirement])]
registryEntries (Registry m) =
  [(n, v, rs) | (n, vs) <- M.toAscList m, (v, rs) <- M.toAscList vs]

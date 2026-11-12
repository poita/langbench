-- |
-- Module      : Depresolve.Version
-- Description : Semantic versions (@MAJOR.MINOR.PATCH@) with numeric ordering.
--
-- Versions have no prerelease or build suffixes.  The derived 'Ord' instance
-- compares major, then minor, then patch, numerically, so @1.10.0 > 1.9.0@.
module Depresolve.Version
  ( Version (..)
  , renderVersion
  , nextPatch
  ) where

-- | A semantic version.
data Version = Version
  { versionMajor :: !Int
  , versionMinor :: !Int
  , versionPatch :: !Int
  }
  deriving (Eq, Ord, Show)

-- | Render as @MAJOR.MINOR.PATCH@.
--
-- >>> renderVersion (Version 1 10 0)
-- "1.10.0"
renderVersion :: Version -> String
renderVersion (Version a b c) = show a ++ "." ++ show b ++ "." ++ show c

-- | The smallest version strictly greater than the argument.  Because
-- versions have no prerelease component, this is the next patch number.  It
-- turns an inclusive bound into an exclusive one.
nextPatch :: Version -> Version
nextPatch (Version a b c) = Version a b (c + 1)

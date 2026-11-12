-- | Semantic versions of the form @MAJOR.MINOR.PATCH@.
module Depresolve.Version
  ( Version (..)
  , mkVersion
  , renderVersion
  , VersionKey
  , versionKey
  , keyBound
  ) where

-- | A semantic version. Components are compared numerically, major first;
-- the derived 'Ord' instance gives exactly that order.
data Version = Version
  { versionMajor :: !Int
  , versionMinor :: !Int
  , versionPatch :: !Int
  }
  deriving (Eq, Ord, Show)

-- | Build a version from its three components.
mkVersion :: Int -> Int -> Int -> Version
mkVersion = Version

-- | Render as @MAJOR.MINOR.PATCH@.
renderVersion :: Version -> String
renderVersion (Version a b c) = show a ++ "." ++ show b ++ "." ++ show c

-- | A version packed into a single 'Int' whose numeric order equals the
-- version order. Each component must be below 2^20 (the specification
-- caps them at 1,000,000), so that bounds one past a version still fit.
type VersionKey = Int

-- | Pack a version into its order-preserving key.
versionKey :: Version -> VersionKey
versionKey (Version a b c) = keyBound a b c

-- | Pack three components (which may be one past a legal maximum, as used
-- for exclusive upper bounds such as @(X+1).0.0@) into a key.
keyBound :: Int -> Int -> Int -> VersionKey
keyBound a b c = (a * 1048576 + b) * 1048576 + c

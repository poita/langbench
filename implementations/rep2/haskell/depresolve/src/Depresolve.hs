-- |
-- Module      : Depresolve
-- Description : Deterministic dependency resolution.
--
-- Given a registry and a root manifest, 'resolve' picks one version per
-- needed package using the depth-first, newest-version-first search with
-- chronological backtracking, and returns the first solution that search
-- finds (or 'Nothing' when there is none).
--
-- > import qualified Data.ByteString.Char8 as B
-- > import Depresolve
-- >
-- > main :: IO ()
-- > main = do
-- >   let input = B.pack "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"
-- >   case parseProblem input of
-- >     Left err -> putStrLn err
-- >     Right p -> mapM_ (\(n, v) -> putStrLn (B.unpack n ++ " " ++ renderVersion v)) (maybe [] id (resolve p))
module Depresolve
  ( -- * Resolving
    resolve
  , resolveText
    -- * Data model
  , Problem (..)
  , PackageVersion (..)
  , Requirement (..)
  , Name
  , Resolution
    -- * Versions and ranges
  , Version (..)
  , renderVersion
  , Range (..)
  , Comparator (..)
  , Op (..)
  , satisfies
    -- * Parsing and rendering
  , parseProblem
  , parseRange
  , parseVersion
  , renderResolution
  ) where

import Data.Array ((!))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as BB

import Depresolve.Index
import Depresolve.Parse
import Depresolve.Range
import Depresolve.Render
import Depresolve.Resolve
import Depresolve.Types
import Depresolve.Version

-- | Resolve a problem.  The result lists every chosen package with its
-- version, sorted by name; 'Nothing' means the search found no solution.
resolve :: Problem -> Maybe Resolution
resolve problem = fmap (map pick) (resolveIndex ix)
  where
    ix = buildIndex problem
    pick (p, i) = (ixNames ix ! p, ixVersions ix ! versionSlot ix p i)

-- | Parse the textual format, resolve, and render the textual answer.
resolveText :: ByteString -> Either String BB.Builder
resolveText input = fmap (renderResolution . resolve) (parseProblem input)

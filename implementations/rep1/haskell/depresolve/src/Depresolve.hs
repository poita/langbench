-- | A deterministic package dependency resolver.
--
-- Given a 'Registry' of package versions (each with its requirements) and a
-- list of root requirements, 'resolve' picks one version for every needed
-- package using a fixed search: depth-first, requirements in the order
-- listed, newest candidate first, chronological backtracking. The result is
-- the first complete solution of that search, so it is reproducible.
--
-- > import Depresolve
-- >
-- > main :: IO ()
-- > main = do
-- >   let Right (reg, root) = parseProblem (B.pack "a 1.0.0:\nroot: a ^1.0.0\n")
-- >   print (resolve reg root)   -- Just [("a", Version 1 0 0)]
module Depresolve
  ( -- * Versions and ranges
    Version (..)
  , mkVersion
  , renderVersion
  , Range (..)
  , Comparator (..)
  , Op (..)
  , satisfies
  , renderRange
    -- * Registries
  , PackageName
  , Requirement (..)
  , Registry
  , emptyRegistry
  , addVersion
  , fromEntries
  , packageNames
  , versionsOf
  , registryEntries
    -- * Parsing
  , parseProblem
  , parseRange
  , parseVersion
    -- * Resolving
  , resolve
  , Resolution
  , renderResolution
  , resolveInput
  ) where

import qualified Data.ByteString.Char8 as B

import Depresolve.Parse
import Depresolve.Range
import Depresolve.Registry
import Depresolve.Resolve
import Depresolve.Version

-- | Render a result as the CLI prints it: @name version@ lines, or the single
-- line @unsatisfiable@.
renderResolution :: Maybe Resolution -> String
renderResolution Nothing = "unsatisfiable\n"
renderResolution (Just xs) = concat [n ++ " " ++ renderVersion v ++ "\n" | (n, v) <- xs]

-- | Parse an input document and render its resolution.
resolveInput :: B.ByteString -> Either String String
resolveInput input = do
  (reg, root) <- parseProblem input
  Right (renderResolution (resolve reg root))

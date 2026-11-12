-- |
-- Module      : Depresolve.Render
-- Description : Output formatting.
module Depresolve.Render
  ( Resolution
  , renderResolution
  ) where

import qualified Data.ByteString.Builder as BB

import Depresolve.Types (Name)
import Depresolve.Version

-- | A successful resolution: one version per chosen package, sorted by name
-- in ascending byte order.
type Resolution = [(Name, Version)]

-- | One @name version@ line per package, or the single line @unsatisfiable@.
renderResolution :: Maybe Resolution -> BB.Builder
renderResolution Nothing = BB.string7 "unsatisfiable\n"
renderResolution (Just r) = mconcat
  [ BB.byteString nm <> BB.char7 ' ' <> BB.string7 (renderVersion v) <> BB.char7 '\n'
  | (nm, v) <- r ]

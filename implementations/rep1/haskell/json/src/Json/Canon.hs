-- |
-- Module      : Json.Canon
-- Description : Strict JSON parsing and canonical serialisation.
--
-- A small, dependency-light JSON library whose purpose is /canonical output/:
--
-- >>> import qualified Data.ByteString.Char8 as B
-- >>> import qualified Data.ByteString.Lazy.Char8 as BL
-- >>> fmap BL.unpack (canonicalize (B.pack "{ \"b\": [1, 2.50, 1E+3], \"a\": \"x\", \"b\": null }"))
-- Right "{\"a\":\"x\",\"b\":null}"
--
-- The pipeline is: strict UTF-8 validation, single-pass recursive-descent
-- parsing into a 'Value' tree ('parse'), then rendering ('render') with
-- sorted, de-duplicated object keys.
module Json.Canon
  ( -- * Document tree
    Value (..)
  , ParseError (..)
    -- * Parsing
  , parse
  , maxDepth
    -- * Rendering
  , render
  , renderLazy
  , renderString
    -- * One-shot
  , canonicalize
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL

import Json.Canon.Parser (maxDepth, parse)
import Json.Canon.Render (render, renderString)
import Json.Canon.Types

-- | Render a value to its canonical form as a lazy 'BL.ByteString' (UTF-8,
-- no trailing newline).
renderLazy :: Value -> BL.ByteString
renderLazy = B.toLazyByteString . render

-- | Parse a document and render it canonically (no trailing newline).
canonicalize :: ByteString -> Either ParseError BL.ByteString
canonicalize = fmap renderLazy . parse

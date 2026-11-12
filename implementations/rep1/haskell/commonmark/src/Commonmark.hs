-- |
-- Module      : Commonmark
-- Description : CommonMark (subset) to HTML conversion.
--
-- A from-scratch implementation of the subset of CommonMark 0.31.2 that has
-- no raw HTML, no link reference definitions and no extensions.  The output
-- matches the @cmark@ reference implementation.
--
-- > import qualified Data.ByteString.Char8 as BC
-- > import Commonmark
-- >
-- > main :: IO ()
-- > main = BC.putStr (commonmarkToHtml (BC.pack "Some *emphasis* and a [link](/url).\n"))
--
-- The conversion has three stages, each available separately:
--
-- 1. "Commonmark.Block" – line-by-line block structure ('parseBlocks');
-- 2. "Commonmark.Inline" – inline structure of paragraphs and headings
--    ('parseInlines');
-- 3. "Commonmark.Html" – rendering ('renderHtml').
module Commonmark
  ( -- * Conversion
    commonmarkToHtml
  , commonmarkToHtmlBuilder
    -- * Parsing
  , parseDocument
    -- * Document tree
  , module Commonmark.Types
    -- * Stages
  , parseBlocks
  , parseInlines
  , renderHtml
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL

import Commonmark.Block (parseBlocks)
import Commonmark.Html (renderHtml)
import Commonmark.Inline (parseInlines)
import Commonmark.Types

-- | Parse a document (UTF-8, LF line endings) into its full block and inline
-- structure.
parseDocument :: ByteString -> [Block [Inline]]
parseDocument = map (fmap parseInlines) . parseBlocks

-- | Convert a Markdown document to HTML.
commonmarkToHtml :: ByteString -> ByteString
commonmarkToHtml = BL.toStrict . BB.toLazyByteString . commonmarkToHtmlBuilder

-- | Like 'commonmarkToHtml', but returns a 'BB.Builder' so the output can be
-- streamed (for example with 'BB.hPutBuilder').
commonmarkToHtmlBuilder :: ByteString -> BB.Builder
commonmarkToHtmlBuilder = renderHtml . parseDocument

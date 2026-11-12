-- | A Markdown-to-HTML converter for the CommonMark subset used by sitegen.
--
-- The supported constructs are thematic breaks, ATX and setext headings,
-- indented and fenced code blocks, paragraphs, block quotes, lists, backslash
-- escapes, entity references, code spans, emphasis, inline links and images,
-- autolinks and line breaks. Raw HTML, link reference definitions and
-- extensions are not supported. The output matches what @cmark@ produces for
-- this subset.
module Sitegen.Markdown
  ( markdownToHtml
  , parseBlocks
  , parseInlines
  , renderBlocks
  , renderInlines
  , Block (..)
  , ListType (..)
  , Inline (..)
  ) where

import Data.Text (Text)

import Sitegen.Markdown.Block (parseBlocks)
import Sitegen.Markdown.Html (renderBlocks, renderInlines)
import Sitegen.Markdown.Inline (parseInlines)
import Sitegen.Markdown.Types

-- | Convert a Markdown document to HTML. The result of a non-empty document
-- ends with a newline; the result of an empty document is empty.
markdownToHtml :: Text -> Text
markdownToHtml = renderBlocks . parseBlocks

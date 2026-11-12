-- |
-- Module      : Commonmark.Types
-- Description : Document tree types shared by the parser and the renderer.
--
-- A parsed document is a list of 'Block's.  The block type is parameterised
-- over the content of its leaf blocks: the block parser
-- ('Commonmark.Block.parseBlocks') produces @['Block' 'ByteString']@ (raw
-- paragraph text), and mapping 'Commonmark.Inline.parseInlines' over it
-- produces the fully parsed @['Block' ['Inline']]@.
module Commonmark.Types
  ( Block (..)
  , ListType (..)
  , Inline (..)
  ) where

import Data.ByteString (ByteString)

-- | Whether a list is a bullet list or an ordered list (with its start number).
data ListType
  = BulletList
  | OrderedList !Int
  deriving (Eq, Show)

-- | A block-level element.  @a@ is the type of the content of paragraphs
-- and headings.
data Block a
  = Paragraph a
  | -- | ATX or setext heading, level 1–6.
    Heading !Int a
  | ThematicBreak
  | -- | A code block (indented or fenced).  The first field is the info
    -- string (already entity-decoded and unescaped; empty for indented
    -- code), the second the literal content.
    CodeBlock ByteString ByteString
  | BlockQuote [Block a]
  | -- | A list: its type, whether it is tight, and its items (each a list
    -- of blocks).
    List ListType Bool [[Block a]]
  deriving (Eq, Show, Functor)

-- | An inline element.  All 'ByteString's are UTF-8.
data Inline
  = Text ByteString
  | SoftBreak
  | LineBreak
  | Code ByteString
  | Emph [Inline]
  | Strong [Inline]
  | -- | Destination, optional title, content.
    Link ByteString (Maybe ByteString) [Inline]
  | -- | Destination, optional title, description (rendered as alt text).
    Image ByteString (Maybe ByteString) [Inline]
  deriving (Eq, Show)

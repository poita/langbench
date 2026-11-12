-- | Abstract syntax of the CommonMark subset.
module Sitegen.Markdown.Types
  ( Block (..)
  , ListType (..)
  , Inline (..)
  ) where

import Data.Text (Text)

-- | A block-level element. Paragraph and heading contents are kept as raw
-- text; they are parsed into 'Inline's when the document is rendered.
data Block
  = BQuote [Block]
  -- ^ A block quote.
  | BList ListType Bool [[Block]]
  -- ^ A list: its type, whether it is tight, and the blocks of each item.
  | BParagraph Text
  | BHeading Int Text
  -- ^ A heading of the given level (1–6) and its raw inline content.
  | BCode Text Text
  -- ^ A code block: the info string (empty if none) and the literal text.
  | BThematicBreak
  deriving (Eq, Show)

-- | The kind of a list.
data ListType
  = BulletList
  | OrderedList Int
  -- ^ An ordered list with the given start number.
  deriving (Eq, Show)

-- | An inline element.
data Inline
  = Str Text
  | SoftBreak
  | HardBreak
  | Code Text
  | Emph [Inline]
  | Strong [Inline]
  | Link Text (Maybe Text) [Inline]
  -- ^ Destination, optional title, link text.
  | Image Text (Maybe Text) [Inline]
  -- ^ Destination, optional title, description.
  deriving (Eq, Show)

-- | The abstract syntax of a parsed Codexa document.
module Typeset.Syntax
  ( Doc (..)
  , Meta (..)
  , Block (..)
  , ListKind (..)
  , ListItem (..)
  , TableElem (..)
  , ColAlign (..)
  , BlockAttrs (..)
  , Inline
  , INode (..)
  , StyleTag (..)
  , emptyMeta
  , noBlockAttrs
  , footnotesOf
  , plainText
  ) where

import Data.List (dropWhileEnd)

import Typeset.Types

-- | A parsed document.
data Doc = Doc
  { docMeta   :: Meta
  , docToc    :: Maybe (Maybe String)
    -- ^ @Just t@ when a @\@toc@ block is present; @t@ is its @title@ attribute
  , docBlocks :: [Block]
  } deriving (Show)

-- | The @\@doc@ metadata (empty strings when unassigned).
data Meta = Meta { metaTitle, metaAuthor, metaDate :: String }
  deriving (Show)

emptyMeta :: Meta
emptyMeta = Meta "" "" ""

-- | Inline style tags.
data StyleTag = TagBold | TagItalic | TagMono | TagLarger | TagSmaller
  deriving (Eq, Show)

-- | A node of inline text.
data INode
  = IChar Char
  | ISpace                       -- ^ one source space
  | IRigid                       -- ^ @~@ or @\\ @ : a rigid space
  | IDisc                        -- ^ @\\-@ : a discretionary point
  | IStyle StyleTag [INode]
  | INote Int [INode]            -- ^ a footnote with its number and text
  deriving (Show)

-- | Inline content.
type Inline = [INode]

-- | Per-column table alignment.
data ColAlign = ColLeft | ColRight | ColCenter
  deriving (Eq, Show)

-- | Optional overrides of a @\@block@.
data BlockAttrs = BlockAttrs
  { baAlign       :: Maybe Align
  , baIndent      :: Maybe Int
  , baRightIndent :: Maybe Int
  , baFont        :: Maybe Family
  , baSize        :: Maybe Int
  , baLeading     :: Maybe Int
  } deriving (Show)

noBlockAttrs :: BlockAttrs
noBlockAttrs = BlockAttrs Nothing Nothing Nothing Nothing Nothing Nothing

-- | Ordered or unordered.
data ListKind = Unordered | Ordered Int
  deriving (Show)

-- | A list item: its own text and the blocks that follow it.
data ListItem = ListItem Inline [Block]
  deriving (Show)

-- | A table row or horizontal rule.
data TableElem = TRow [Inline] | THRule
  deriving (Show)

-- | A block of the document.
data Block
  = BPara Inline
  | BHeading Int Bool Inline            -- ^ level, starred (unnumbered), text
  | BQuote [Block]
  | BGroup BlockAttrs [Block]
  | BList ListKind [ListItem]
  | BTable Int [ColAlign] [TableElem]
  | BPre [String]
  | BFig Int (Maybe Int) Inline          -- ^ height, optional width, caption
  | BRule
  | BVSpace Int
  | BNewPage
  deriving (Show)

-- | The footnotes of an inline text, in source order.
footnotesOf :: Inline -> [(Int, Inline)]
footnotesOf = concatMap go
  where
    go n = case n of
      INote k body -> [(k, body)]
      IStyle _ b -> footnotesOf b
      _ -> []

-- | The plain text of a heading: styles removed, @\\-@ dropped, rigid
-- spaces turned into spaces, space runs collapsed, ends trimmed.
plainText :: Inline -> String
plainText nodes = dropWhileEnd (== ' ') (dropWhile (== ' ') (collapse (concatMap flat nodes)))
  where
    flat n = case n of
      IChar c -> [c]
      ISpace -> " "
      IRigid -> " "
      IDisc -> ""
      IStyle _ b -> concatMap flat b
      INote _ _ -> ""
    collapse (' ' : ' ' : r) = collapse (' ' : r)
    collapse (c : r) = c : collapse r
    collapse [] = []

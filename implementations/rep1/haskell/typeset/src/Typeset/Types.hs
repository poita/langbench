-- | Small enumerations shared between the settings, parser and layout code.
module Typeset.Types
  ( Family (..)
  , Align (..)
  , PatternName (..)
  ) where

-- | A font family.  Bold and italic variants are resolved separately.
data Family = Serif | Sans | Mono
  deriving (Eq, Ord, Show)

-- | Paragraph alignment.
data Align = Justify | AlignLeft | AlignRight | AlignCenter
  deriving (Eq, Ord, Show)

-- | Which hyphenation pattern set is active.
data PatternName = English | Minimal
  deriving (Eq, Ord, Show)

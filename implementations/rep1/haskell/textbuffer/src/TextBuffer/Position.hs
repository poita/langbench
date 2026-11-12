-- |
-- Module      : TextBuffer.Position
-- Description : Line/column positions in a document.
--
-- A 'Pos' is a zero-based @(line, column)@ pair. Positions are ordered
-- lexicographically, which coincides with the order of their character
-- offsets in the document text.
module TextBuffer.Position
  ( Pos (..)
  , origin
  , advance
  ) where

import qualified Data.ByteString.Char8 as B

-- | A zero-based position. The derived 'Ord' compares the line first, then
-- the column.
data Pos = Pos
  { posLine :: {-# UNPACK #-} !Int
  , posCol  :: {-# UNPACK #-} !Int
  } deriving (Eq, Ord, Show)

-- | The start of the document, @(0, 0)@.
origin :: Pos
origin = Pos 0 0

-- | @advance p t@ is the position reached after inserting text @t@ (which
-- may contain newlines) at position @p@: the end of the inserted text.
advance :: Pos -> B.ByteString -> Pos
advance (Pos l c) t = case B.elemIndexEnd '\n' t of
  Nothing -> Pos l (c + B.length t)
  Just i  -> Pos (l + B.count '\n' t) (B.length t - i - 1)

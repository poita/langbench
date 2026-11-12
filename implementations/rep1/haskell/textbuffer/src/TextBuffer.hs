-- |
-- Module      : TextBuffer
-- Description : A text buffer with multiple cursors, undo and redo.
--
-- The editing core of a text editor. A 'Buffer' holds a document of lines
-- and a set of cursors, each optionally holding a selection. Commands
-- ('Command') insert and delete text at every cursor, move the cursors
-- (remembering a goal column for vertical movement), and undo / redo whole
-- edits.
--
-- > import TextBuffer
-- > import qualified Data.ByteString.Char8 as B
-- >
-- > main :: IO ()
-- > main = do
-- >   let b0 = fromLines [B.pack "hello"]
-- >       Right cmds = mapM (parseCommand . B.pack) ["move end", "insert !"]
-- >       b1 = foldl (flip execute) b0 cmds
-- >   print (map B.unpack (Doc.toLines (document b1)))   -- ["hello!"]
-- >   print (map curHead (cursors b1))                     -- [Pos 0 6]
module TextBuffer
  ( -- * Buffers
    Buffer
  , empty
  , fromLines
  , fromDocument
  , document
  , cursors
  , canUndo
  , canRedo
  , execute
  , undo
  , redo
  , render
    -- * Commands
  , Command (..)
  , Direction (..)
  , parseCommand
    -- * Cursors and positions
  , Cursor (..)
  , Pos (..)
  , rangeStart
  , rangeEnd
  , hasSelection
    -- * Documents
  , Document
    -- * Scripts
  , parseScript
  , runScript
  ) where

import TextBuffer.Buffer
import TextBuffer.Command
import TextBuffer.Cursor
import TextBuffer.Document (Document)
import TextBuffer.Position
import TextBuffer.Script

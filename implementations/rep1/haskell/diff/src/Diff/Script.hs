-- |
-- Module      : Diff.Script
-- Description : The textual edit-script format.
--
-- A script is a count line followed by that many script lines.  Each script
-- line is a one-character tag (space = keep, @-@ = delete, @+@ = insert)
-- followed immediately by the line's content, which may be empty.
module Diff.Script
  ( renderEdit
  , renderScript
  , parseEdit
  ) where

import qualified Data.ByteString         as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8   as BC

import           Diff.Types

-- | One script line, newline-terminated.
renderEdit :: Edit B.ByteString -> BB.Builder
renderEdit e = BB.word8 tag <> BB.byteString content <> BB.char7 '\n'
  where
    (tag, content) = case e of
      Keep c   -> (32, c)
      Delete c -> (45, c)
      Insert c -> (43, c)

-- | The whole script: the number of lines, then the lines.
renderScript :: [Edit B.ByteString] -> BB.Builder
renderScript es = BB.intDec (length es) <> BB.char7 '\n' <> foldMap renderEdit es

-- | Parse one script line (without its newline).
parseEdit :: B.ByteString -> Either String (Edit B.ByteString)
parseEdit l = case BC.uncons l of
  Just (' ', c) -> Right (Keep c)
  Just ('-', c) -> Right (Delete c)
  Just ('+', c) -> Right (Insert c)
  Just (t, _)   -> Left ("bad tag " ++ show t ++ " in script line " ++ show l)
  Nothing       -> Left "empty script line"

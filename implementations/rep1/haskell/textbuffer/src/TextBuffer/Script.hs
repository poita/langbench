{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : TextBuffer.Script
-- Description : Running a whole script: initial document plus commands.
--
-- The script format is the one read by the @textbuffer@ executable: a line
-- with the number @N@ of document lines, those @N@ lines verbatim, then one
-- command per line.
module TextBuffer.Script
  ( parseScript
  , runScript
  ) where

import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Char8 as B

import TextBuffer.Buffer
import TextBuffer.Command

-- | Split a script into the initial buffer and its commands. Fails on a
-- malformed header or command (reporting the line number).
parseScript :: B.ByteString -> Either String (Buffer, [Command])
parseScript input = do
  (hdr, rest) <- case B.lines input of
    []     -> Left "empty input: expected the document line count"
    (h:ls) -> Right (h, ls)
  n <- case B.readInt (B.strip hdr) of
    Just (k, r) | B.null r, k >= 0 -> Right k
    _ -> Left "line 1: expected a non-negative line count"
  let (docLines, cmdLines) = splitAt n rest
  cmds <- mapM parseAt (zip [n + 2 ..] cmdLines)
  Right (fromLines docLines, cmds)
  where
    parseAt (i, l) = either (\e -> Left ("line " ++ show (i :: Int) ++ ": " ++ e)) Right
                            (parseCommand l)

-- | Run a script and collect the output of every @print@. The output is
-- produced lazily, command by command.
runScript :: B.ByteString -> Either String Builder
runScript input = do
  (b0, cmds) <- parseScript input
  Right (go b0 cmds)
  where
    go _ [] = mempty
    go b (Print : cs) = render b <> go b cs
    go b (c : cs) = let !b' = execute c b in go b' cs

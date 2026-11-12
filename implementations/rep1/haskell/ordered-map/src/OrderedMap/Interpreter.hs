{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : OrderedMap.Interpreter
-- Description : Executes command scripts against a "Data.OrderedMap"
--
-- Runs the command language of "OrderedMap.Command" and renders each
-- command's answer as one output line.
--
-- Script format: the first line holds the number of commands @Q@; the
-- following @Q@ lines are commands. The output has exactly one line per
-- command, each terminated by @\\n@.
module OrderedMap.Interpreter
  ( Store
  , execute
  , runCommands
  , runScript
  ) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B
import Data.List (intersperse)

import qualified Data.OrderedMap as OM
import OrderedMap.Command

-- | The map the interpreter operates on.
type Store = OM.OrderedMap Int B.ByteString

-- | Execute one command: the line of output (without newline) and the new
-- map.
execute :: Command -> Store -> (BB.Builder, Store)
execute cmd m = case cmd of
  Insert k v -> case OM.insertLookup k v m of
    (old, m') -> (word (maybe "ok" (const "updated") old), m')
  Delete k -> case OM.deleteLookup k m of
    (old, m') -> (word (maybe "missing" (const "ok") old), m')
  Get k -> (maybe missing BB.byteString (OM.lookup k m), m)
  Size -> (BB.intDec (OM.size m), m)
  Min -> (maybe (word "empty") (BB.intDec . fst) (OM.lookupMin m), m)
  Max -> (maybe (word "empty") (BB.intDec . fst) (OM.lookupMax m), m)
  Floor k -> (key (OM.lookupFloor k m), m)
  Ceil k -> (key (OM.lookupCeil k m), m)
  Succ k -> (key (OM.lookupSucc k m), m)
  Pred k -> (key (OM.lookupPred k m), m)
  Rank k -> (BB.intDec (OM.rank k m), m)
  Select i -> (key (OM.select i m), m)
  Range lo hi -> (rangeLine (OM.rangeKeys lo hi m), m)
  where
    word = BB.byteString
    missing = word "missing"
    key = maybe missing (BB.intDec . fst)
    rangeLine [] = word "empty"
    rangeLine ks = mconcat (intersperse (BB.char7 ' ') (map BB.intDec ks))

-- | Run a list of commands from an empty map, producing the whole output
-- (one newline-terminated line per command). The output is produced lazily,
-- so it can be streamed.
runCommands :: [Command] -> BB.Builder
runCommands = go OM.empty
  where
    go _ [] = mempty
    go !m (c : cs) = case execute c m of
      (out, m') -> out <> BB.char7 '\n' <> go m' cs

-- | Run a whole script (@Q@ followed by @Q@ command lines). Parsing is done
-- up front, so on a malformed script nothing is produced and the first error
-- is returned.
runScript :: B.ByteString -> Either String BB.Builder
runScript input = case B.lines input of
  [] -> Right mempty
  (header : rest) -> do
    q <- case B.readInt (B.strip header) of
      Just (n, r) | B.null r, n >= 0 -> Right n
      _ -> Left ("malformed command count: " ++ show (B.unpack header))
    cmds <- traverse parseCommand (take q rest)
    if length cmds < q
      then Left ("expected " ++ show q ++ " commands, found " ++ show (length cmds))
      else Right (runCommands cmds)

-- |
-- Module      : Git.Command
-- Description : The command language: parsing a line and running it.
module Git.Command
  ( Command (..)
  , parseCommand
  , runCommand
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC

import Git.Query
import Git.Store (Repository)

-- | A parsed command line.
data Command
  = Log ByteString (Maybe Integer)
  | LsTree ByteString (Maybe ByteString)
  | CatFile ByteString
  | Diff ByteString ByteString
  | RevParse ByteString
  | CountObjects
  deriving (Eq, Show)

-- | Parse one command line.  Tokens are separated by single spaces, so an
-- empty token (from two adjacent spaces or a trailing space) is kept and is
-- an argument like any other; @log@'s limit must be a run of decimal digits.
parseCommand :: ByteString -> Either String Command
parseCommand line = case BS.split 32 line of
  [c, rev] | c == BC.pack "log" -> Right (Log rev Nothing)
  [c, rev, n] | c == BC.pack "log" -> case parseNat n of
    Just k -> Right (Log rev (Just k))
    Nothing -> Left "log: bad count"
  [c, rev] | c == BC.pack "ls-tree" -> Right (LsTree rev Nothing)
  [c, rev, p] | c == BC.pack "ls-tree" -> Right (LsTree rev (Just p))
  [c, rev] | c == BC.pack "cat-file" -> Right (CatFile rev)
  [c, a, b] | c == BC.pack "diff" -> Right (Diff a b)
  [c, rev] | c == BC.pack "rev-parse" -> Right (RevParse rev)
  [c] | c == BC.pack "count-objects" -> Right CountObjects
  _ -> Left "unknown command or wrong number of arguments"
  where
    parseNat n
      | not (BS.null n) && BC.all (\ch -> ch >= '0' && ch <= '9') n =
          Just (BS.foldl' (\a ch -> a * 10 + toInteger ch - 48) 0 n)
      | otherwise = Nothing

-- | Run a command; the result is the exact output.  Throws 'Git.Types.GitError'
-- on failure.
runCommand :: Repository -> Command -> IO ByteString
runCommand repo cmd = case cmd of
  Log rev n -> logHistory repo rev n
  LsTree rev p -> lsTree repo rev p
  CatFile rev -> catFile repo rev
  Diff a b -> diffTrees repo a b
  RevParse rev -> revParse repo rev
  CountObjects -> pure (countObjects repo)

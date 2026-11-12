-- |
-- Module      : Diff.Protocol
-- Description : The stdin/stdout protocol of the command-line tool.
--
-- The first input line is the mode (@diff@ or @patch@), followed by two
-- count-prefixed blocks of lines.  Content is always read by the declared
-- counts, never interpreted.  See the README for the full format.
module Diff.Protocol
  ( Request (..)
  , parseRequest
  , runRequest
  , process
  ) where

import qualified Data.ByteString         as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8   as BC
import           Data.Char               (isDigit)

import           Diff
import           Diff.Script

-- | A parsed job.
data Request
  = DiffRequest  [B.ByteString] [B.ByteString]
    -- ^ lines of A and of B
  | PatchRequest [B.ByteString] [Edit B.ByteString]
    -- ^ lines of A and an edit script
  deriving (Eq, Show)

-- | Parse a whole input.  Extra trailing empty lines and a missing final
-- newline are tolerated.
parseRequest :: B.ByteString -> Either String Request
parseRequest input = case BC.lines input of
  [] -> Left "empty input"
  (mode : rest)
    | mode == BC.pack "diff" -> do
        (as, rest1) <- block "N" Right rest
        (bs, _)     <- block "M" Right rest1
        pure (DiffRequest as bs)
    | mode == BC.pack "patch" -> do
        (as, rest1) <- block "N" Right rest
        (es, _)     <- block "K" parseEdit rest1
        pure (PatchRequest as es)
    | otherwise -> Left ("unknown mode " ++ show mode)
  where
    block name conv ls = case ls of
      [] -> Left ("missing count " ++ name)
      (c : more) -> do
        n <- parseCount name c
        let (body, rest) = splitAt n more
        if length body < n
          then Left ("expected " ++ show n ++ " lines after " ++ name)
          else do
            xs <- traverse conv body
            pure (xs, rest)

parseCount :: String -> B.ByteString -> Either String Int
parseCount name raw
  | null s || not (all isDigit s) = Left ("bad count " ++ name ++ ": " ++ show raw)
  | otherwise                     = Right (read s)
  where
    s = BC.unpack (BC.dropWhileEnd (\c -> c == ' ' || c == '\t') raw)

-- | Execute a request, producing the exact bytes to write to stdout.
runRequest :: Request -> Either String BB.Builder
runRequest (DiffRequest as bs) = Right (renderScript (diff as bs))
runRequest (PatchRequest as es) =
  case patch as es of
    Left err -> Left ("invalid script: " ++ show err)
    Right out -> Right (BB.intDec (length out) <> BB.char7 '\n'
                        <> foldMap (\l -> BB.byteString l <> BB.char7 '\n') out)

-- | 'parseRequest' followed by 'runRequest'.
process :: B.ByteString -> Either String BB.Builder
process input = parseRequest input >>= runRequest

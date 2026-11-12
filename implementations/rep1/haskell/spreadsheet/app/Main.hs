-- | Command-line front end: reads a script of @set@ / @get@ / @clear@ /
-- @dump@ commands (one per line) from standard input and writes the results
-- of @get@ and @dump@ to standard output.  Malformed lines are reported on
-- standard error and skipped.
module Main (main) where

import Control.Monad (foldM_, unless)
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.IO

import Spreadsheet

main :: IO ()
main = do
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- B.getContents
  let ls = filter (not . B.null) (B.split 10 input)
  foldM_ step empty ls
  hFlush stdout
  where
    step sheet raw = do
      let line = TE.decodeUtf8With TE.lenientDecode raw
      case parseCommand line of
        Left (ParseError msg) -> do
          hPutStrLn stderr ("spreadsheet: " ++ msg)
          pure sheet
        Right cmd -> do
          let (sheet', out) = execute cmd sheet
          unless (null out) $ B.hPut stdout (TE.encodeUtf8 (T.unlines out))
          pure $! sheet'

-- | Command-line front end: reads a batch of patterns and subjects on stdin
-- and writes one result line per subject to stdout.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO

import Text.Regex.Backtrack.Batch

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> pure ()
    _  -> hPutStrLn stderr "usage: regex-backtrack < input > output" >> exitWith (ExitFailure 2)
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering (Just 65536))
  input <- B.getContents
  res <- runBatch (BB.hPutBuilder stdout) input
  hFlush stdout
  case res of
    Right () -> pure ()
    Left err -> hPutStrLn stderr ("error: " ++ show err) >> exitWith (ExitFailure 1)

-- | Command-line front end: reads a batch of patterns and subjects on stdin
-- and writes one result line per subject on stdout.
module Main (main) where

import qualified Data.ByteString as B
import System.Exit (exitFailure)
import System.IO

import Regex.Batch (BatchError (..), runBatch)
import Regex.Parser (ParseError (..))

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering (Just 65536))
  input <- B.getContents
  r <- runBatch input stdout
  hFlush stdout
  case r of
    Right () -> pure ()
    Left err -> do
      hPutStrLn stderr ("regex-backtrack: " ++ describe err)
      exitFailure

describe :: BatchError -> String
describe (MalformedInput m) = "malformed input: " ++ m
describe (BadPattern i p (ParseError off msg)) =
  "pattern " ++ show i ++ " (" ++ show p ++ "): " ++ msg ++ " at offset " ++ show off

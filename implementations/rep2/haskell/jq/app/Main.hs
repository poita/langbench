-- | Command-line tool: reads a filter (first line) and a JSON document
-- (the rest) from stdin and prints each result as compact JSON.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import System.Exit (exitWith, ExitCode (..))
import System.IO

import Jq (processInput)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering (Just 65536))
  input <- B.getContents
  case processInput input of
    Left err -> hPutStrLn stderr ("jq-hs: " ++ err) >> exitWith (ExitFailure 2)
    Right out -> BB.hPutBuilder stdout out >> hFlush stdout

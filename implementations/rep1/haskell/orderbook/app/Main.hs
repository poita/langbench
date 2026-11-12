-- | Command-line front end: reads commands on stdin, writes events to stdout.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import System.IO

import OrderBook (processInput)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering (Just 65536))
  input <- B.getContents
  BB.hPutBuilder stdout (processInput input)
  hFlush stdout

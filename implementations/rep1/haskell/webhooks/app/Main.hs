-- | Command-line front end: reads commands on stdin, writes results to stdout.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import System.IO (BufferMode (BlockBuffering), hSetBinaryMode, hSetBuffering, stdin, stdout)
import Webhooks.Command (processInput)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- BS.getContents
  B.hPutBuilder stdout (processInput input)

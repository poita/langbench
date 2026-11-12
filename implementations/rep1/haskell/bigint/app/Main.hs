-- | Command-line front end: reads queries from stdin, writes one result line
-- per query to stdout.  See the README for the format.
module Main (main) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as BC
import System.IO (hSetBinaryMode, stdin, stdout)

import Query (evalAll)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  input <- BC.getContents
  BB.hPutBuilder stdout (foldMap (\l -> BB.byteString l <> BB.char7 '\n') (evalAll input))

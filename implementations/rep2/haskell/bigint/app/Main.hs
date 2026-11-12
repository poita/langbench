-- | Command-line front end: reads queries (@a op b@, one per line) from
-- standard input and writes one result line per query to standard output.
module Main (main) where

import qualified Data.ByteString as B
import Numeric.BigInt.Query (evalInput)
import System.IO (stdout, hSetBinaryMode)

main :: IO ()
main = do
  hSetBinaryMode stdout True
  B.getContents >>= B.putStr . evalInput

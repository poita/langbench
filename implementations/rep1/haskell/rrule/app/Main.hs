-- | Command-line front end: reads rules on stdin, writes occurrences on stdout.
module Main (main) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import RRule.Batch (processInput)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, hSetBinaryMode, stderr, stdout)

main :: IO ()
main = do
  input <- BL.getContents
  hSetBinaryMode stdout True
  case processInput input of
    Left err -> hPutStrLn stderr ("rrule: " ++ err) >> exitFailure
    Right out -> B.hPutBuilder stdout out

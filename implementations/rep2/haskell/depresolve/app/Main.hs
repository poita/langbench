-- | Command-line front end: reads a problem on stdin, writes the resolution
-- (or @unsatisfiable@) on stdout.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import System.Exit (exitFailure)
import System.IO (hPutStrLn, hSetBinaryMode, stderr, stdin, stdout)

import Depresolve (resolveText)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  input <- B.getContents
  case resolveText input of
    Left err -> hPutStrLn stderr ("depresolve: " ++ err) >> exitFailure
    Right out -> BB.hPutBuilder stdout out

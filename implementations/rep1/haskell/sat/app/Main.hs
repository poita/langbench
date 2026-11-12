-- | Command-line front end: reads DIMACS CNF on stdin and prints @UNSAT@ or
-- @SAT@ followed by a model line.
module Main (main) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS
import System.Exit (exitFailure)
import System.IO (hPutStrLn, hSetBinaryMode, stderr, stdout)

import Sat

main :: IO ()
main = do
  input <- BS.getContents
  case parseDimacs input of
    Left err -> hPutStrLn stderr ("sat: " ++ err) >> exitFailure
    Right cnf -> do
      hSetBinaryMode stdout True
      B.hPutBuilder stdout (renderResult (solve cnf))

-- | Command-line front end: read DIMACS CNF on stdin, print @SAT@ and a model
-- or @UNSAT@ on stdout.
module Main (main) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, hSetBinaryMode, stderr, stdout)

import Sat (parseDimacs, renderResult, solve)

main :: IO ()
main = do
  input <- BS.getContents
  case parseDimacs input of
    Left err -> hPutStrLn stderr ("sat: " ++ err) >> exitWith (ExitFailure 2)
    Right cnf -> do
      hSetBinaryMode stdout True
      B.hPutBuilder stdout (renderResult (solve cnf))

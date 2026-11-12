-- | Command-line front end: reads the registry and root manifest on stdin and
-- prints the resolution on stdout.
module Main (main) where

import qualified Data.ByteString.Char8 as B
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

import Depresolve (resolveInput)

main :: IO ()
main = do
  input <- B.getContents
  case resolveInput input of
    Right out -> putStr out
    Left err -> hPutStrLn stderr ("depresolve: " ++ err) >> exitWith (ExitFailure 1)

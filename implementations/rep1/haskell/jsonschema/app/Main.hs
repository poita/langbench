-- | Command-line front end: reads a request document on stdin and prints one
-- @valid@ / @invalid@ line per instance.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.Text.IO as T
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

import JsonSchema (processBytes)

main :: IO ()
main = do
  hSetEncoding stdout utf8
  input <- B.getContents
  case processBytes input of
    Left err -> hPutStrLn stderr ("jsonschema: " ++ err) >> exitWith (ExitFailure 1)
    Right out -> T.putStr out

-- | Command-line front end: @buildsys INPUT_DIR OUTPUT_DIR@.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

import Kiln (runDirectory)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, output] -> runDirectory input output
    _ -> do
      hPutStrLn stderr "usage: buildsys INPUT_DIR OUTPUT_DIR"
      exitWith (ExitFailure 2)

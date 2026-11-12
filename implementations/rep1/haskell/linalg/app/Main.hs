-- | Command line driver: @linalg <input directory> <output directory>@.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (ExitFailure))
import System.IO (hPutStrLn, stderr)

import Linalg.Runner (runDirectory)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, output] -> runDirectory input output
    _ -> do
      hPutStrLn stderr "usage: linalg <input directory> <output directory>"
      exitWith (ExitFailure 2)

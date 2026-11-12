-- | Command-line front end: @gitrepo \<input path\> \<output dir\>@.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Git (runBatch)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, out] -> runBatch input out
    _ -> do
      hPutStrLn stderr "usage: gitrepo <input path> <output dir>"
      exitFailure

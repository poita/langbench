-- | Command-line entry point: @mime-dump \<input path\> \<output dir\>@.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

import Mime (dumpMailbox)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, out] -> dumpMailbox input out
    _ -> do
      hPutStrLn stderr "usage: mime-dump <mbox file | directory of .eml files> <output directory>"
      exitWith (ExitFailure 2)

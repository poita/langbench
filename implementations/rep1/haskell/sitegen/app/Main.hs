-- | Command-line front end: @sitegen <input directory> <output directory>@.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Sitegen (generateSite)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, output] -> do
      result <- generateSite input output
      case result of
        Right () -> pure ()
        Left err -> hPutStrLn stderr ("sitegen: " ++ err) >> exitFailure
    _ -> do
      hPutStrLn stderr "usage: sitegen <input directory> <output directory>"
      exitFailure

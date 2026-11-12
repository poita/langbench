-- | Command-line front end:
--
-- > typeset [--data DIR] <input directory> <output directory>
--
-- Fonts and hyphenation patterns are read from @DIR@ (default @data@,
-- relative to the current directory).
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Typeset (runDirectory)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [inDir, outDir] -> runDirectory "data" inDir outDir
    ["--data", dataDir, inDir, outDir] -> runDirectory dataDir inDir outDir
    _ -> do
      hPutStrLn stderr "usage: typeset [--data DIR] <input directory> <output directory>"
      exitFailure

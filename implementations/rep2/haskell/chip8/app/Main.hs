-- | Command-line front end: reads the input from stdin, writes the report to
-- stdout.  Exits with status 1 and a message on stderr if the input is
-- malformed.
module Main (main) where

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Chip8

main :: IO ()
main = do
  txt <- getContents
  case parseInput txt of
    Left err -> hPutStrLn stderr ("chip8: " ++ err) >> exitFailure
    Right inp -> putStr (render (runInput inp))

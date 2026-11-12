-- | Command-line front end: reads a program description on stdin and prints
-- the final display and CPU state on stdout.
module Main (main) where

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Chip8

main :: IO ()
main = do
  txt <- getContents
  case parseInput txt of
    Left err -> hPutStrLn stderr ("chip8: " ++ err) >> exitFailure
    Right inp -> putStr (renderSnapshot (run inp))

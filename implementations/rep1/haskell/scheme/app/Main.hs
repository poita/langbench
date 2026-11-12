-- | Command-line tool: read a Scheme program on stdin, write its output on
-- stdout.  Exit status is always 0; runtime errors of the Scheme program are
-- reported in the output as @error: <category>@.
module Main (main) where

import System.IO

import Scheme (runProgram)

main :: IO ()
main = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  hSetNewlineMode stdin noNewlineTranslation
  hSetNewlineMode stdout noNewlineTranslation
  hSetBuffering stdout (BlockBuffering Nothing)
  src <- getContents
  runProgram (hPutStr stdout) src
  hFlush stdout

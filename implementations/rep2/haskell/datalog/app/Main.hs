-- | Command-line front end: reads a Datalog program on stdin, prints the
-- answers to its queries, or @error@ if it is unsafe or not stratifiable.
module Main (main) where

import Datalog (renderResults, runProgram)

main :: IO ()
main = do
  src <- getContents
  putStr (either (const "error\n") renderResults (runProgram src))

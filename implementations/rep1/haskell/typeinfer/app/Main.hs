-- | Command-line front end: reads a program on stdin, prints one line per
-- declaration on stdout.
module Main (main) where

import System.Exit (exitWith, ExitCode (..))
import System.IO

import Language.TypeInfer

main :: IO ()
main = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  hSetBuffering stdout (BlockBuffering Nothing)
  src <- getContents
  case inferSource src of
    Left err -> do
      hPutStrLn stderr ("typeinfer: " ++ renderParseError err)
      exitWith (ExitFailure 1)
    Right results -> mapM_ (putStrLn . renderResult) results

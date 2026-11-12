-- | Command-line driver: reads a script on stdin (document, then commands)
-- and writes the output of every @print@ to stdout.
module Main (main) where

import Data.ByteString.Builder (hPutBuilder)
import qualified Data.ByteString.Char8 as B
import System.Exit (exitFailure)
import System.IO

import TextBuffer

main :: IO ()
main = do
  input <- B.getContents
  case runScript input of
    Left err -> hPutStrLn stderr ("textbuffer: " ++ err) >> exitFailure
    Right out -> do
      hSetBinaryMode stdout True
      hSetBuffering stdout (BlockBuffering (Just 65536))
      hPutBuilder stdout out
      hFlush stdout

-- | Command-line front end: reads a request on stdin, writes the answer on
-- stdout.  See the README for the protocol.
module Main (main) where

import qualified Data.ByteString    as B
import qualified Data.ByteString.Builder as BB
import           System.Exit        (exitWith, ExitCode (..))
import           System.IO

import           Diff.Protocol      (process)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  input <- B.getContents
  case process input of
    Left err -> hPutStrLn stderr ("diff-cli: " ++ err) >> exitWith (ExitFailure 1)
    Right out -> do
      hSetBuffering stdout (BlockBuffering Nothing)
      BB.hPutBuilder stdout out
      hFlush stdout

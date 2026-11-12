-- | Command-line front end: reads a command script on stdin, writes one
-- answer line per command on stdout. See the README for the format.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import System.Exit (exitFailure)
import System.IO

import OrderedMap.Interpreter (runScript)

main :: IO ()
main = do
  input <- B.getContents
  case runScript input of
    Left err -> hPutStrLn stderr ("ordered-map: " ++ err) >> exitFailure
    Right out -> do
      hSetBinaryMode stdout True
      hSetBuffering stdout (BlockBuffering (Just 65536))
      BB.hPutBuilder stdout out
      hFlush stdout

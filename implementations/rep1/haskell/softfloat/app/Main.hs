-- | Command-line tool: reads operations on stdin, writes results on stdout.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as L
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Numeric.SoftFloat.Protocol (processInput)

main :: IO ()
main = do
  inp <- BS.getContents
  case processInput inp of
    Left err -> hPutStrLn stderr ("softfloat: " ++ err) >> exitFailure
    Right out -> L.putStr out

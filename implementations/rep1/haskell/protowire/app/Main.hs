-- | Command-line front end: schema and requests on stdin, results on stdout.
module Main (main) where

import qualified Data.ByteString as BS
import Data.ByteString.Builder (hPutBuilder)
import System.Exit (exitWith, ExitCode (..))
import System.IO

import Protowire (processInput)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- BS.getContents
  case processInput input of
    Left err -> do
      hPutStrLn stderr ("protowire: invalid schema: " ++ show err)
      exitWith (ExitFailure 1)
    Right out -> hPutBuilder stdout out

-- | Command-line front end: read a Datalog program on stdin, answer its
-- queries on stdout (or print @error@ for an unsafe / unstratifiable program).
module Main (main) where

import qualified Data.ByteString as B
import Data.ByteString.Builder (hPutBuilder)
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, hSetBinaryMode, stderr, stdin, stdout)

import Datalog (ParseError (..), runSource)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  src <- B.getContents
  case runSource src of
    Right out -> hPutBuilder stdout out
    Left (ParseError msg) -> do
      hPutStrLn stderr ("syntax error: " ++ msg)
      exitWith (ExitFailure 1)

-- | Command-line front end: read a SQL script on stdin, print the results of
-- every SELECT (and @error@ for every failing statement) on stdout.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.ByteString.Lazy as BL
import System.IO (stdout, hSetBinaryMode)

import MiniSQL (renderScript)

main :: IO ()
main = do
  input <- BS.getContents
  hSetBinaryMode stdout True
  BL.putStr (TLE.encodeUtf8 (renderScript (TE.decodeUtf8With TE.lenientDecode input)))

-- | Command-line front end: reads a hex-encoded raw DEFLATE stream on stdin and
-- prints the hex-encoded decompressed bytes, or the word @error@ if the stream
-- is malformed.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isSpace)
import System.IO (stdin, stdout, hSetBinaryMode)

import Codec.Compression.Inflate (inflate)
import Codec.Compression.Inflate.Hex (decodeHex, encodeHex)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  txt <- B.getContents
  let result = do
        raw <- decodeHex (BC.dropWhileEnd isSpace (BC.dropWhile isSpace txt))
        either (const Nothing) Just (inflate raw)
  B.hPut stdout $ case result of
    Just out -> encodeHex out `B.append` BC.pack "\n"
    Nothing -> BC.pack "error\n"

-- | Command-line tool: read one JSON document from stdin and print its
-- canonical form (or @invalid@) followed by a newline. Always exits 0.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import System.IO (BufferMode (..), hSetBinaryMode, hSetBuffering, stdin, stdout)

import Json.Canon (parse, render)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- BS.getContents
  case parse input of
    Left _ -> B.hPutBuilder stdout (B.string7 "invalid\n")
    Right v -> B.hPutBuilder stdout (render v <> B.char7 '\n')

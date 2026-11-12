-- | Command-line interface: reads Markdown on stdin, writes HTML on stdout.
module Main (main) where

import qualified Data.ByteString as B
import Data.ByteString.Builder (hPutBuilder)
import System.IO (BufferMode (..), hSetBinaryMode, hSetBuffering, stdin, stdout)

import Commonmark (commonmarkToHtmlBuilder)

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- B.getContents
  hPutBuilder stdout (commonmarkToHtmlBuilder input)

-- | Command-line front end: reads a match file on stdin, writes the log to stdout.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.IO

import Spiremark (runMatchText)

main :: IO ()
main = do
  raw <- B.getContents
  let input = T.unpack (TE.decodeUtf8With TE.lenientDecode raw)
  hSetEncoding stdout utf8
  hSetBuffering stdout (BlockBuffering Nothing)
  out <- runMatchText input
  mapM_ putStrLn out
  hFlush stdout
  return ()

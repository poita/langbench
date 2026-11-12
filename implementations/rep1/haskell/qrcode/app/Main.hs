-- | Command-line tool: reads queries from stdin, prints symbols to stdout.
module Main (main) where

import Data.ByteString.Builder (hPutBuilder)
import qualified Data.ByteString as B
import System.Exit (exitFailure)
import System.IO

import Codec.QRCode.Query (processInput)

main :: IO ()
main = do
  input <- B.getContents
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  mapM_ emit (zip [1 :: Int ..] (processInput input))
  hFlush stdout
  where
    emit (_, Right out) = hPutBuilder stdout out
    emit (i, Left err) = do
      hFlush stdout
      hPutStrLn stderr ("qrcode: query " ++ show i ++ ": " ++ err)
      exitFailure

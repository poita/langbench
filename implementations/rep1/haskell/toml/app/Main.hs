-- | Command-line front end.
--
-- Standard input is a mode line (@decode@ or @encode@) followed by the
-- document.  @decode@ prints tagged JSON (or @error@), @encode@ reads tagged
-- JSON and prints canonical TOML.
module Main (main) where

import qualified Data.ByteString as B
import Data.ByteString.Builder (hPutBuilder, char7, string7)
import System.Exit (exitWith, ExitCode (..))
import System.IO

import Toml

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  input <- B.getContents
  let (modeLine, rest) = B.break (== 10) input
      doc = B.drop 1 rest
  case modeLine of
    m | m == B.pack (map (fromIntegral . fromEnum) "decode") ->
          case decode doc of
            Left err -> do
              hPutStrLn stderr (renderDecodeError err)
              hPutBuilder stdout (string7 "error\n")
            Right t -> hPutBuilder stdout (renderTaggedJson t <> char7 '\n')
      | m == B.pack (map (fromIntegral . fromEnum) "encode") ->
          case parseTaggedJson doc of
            Left err -> hPutStrLn stderr ("invalid tagged JSON: " ++ err) >> exitWith (ExitFailure 1)
            Right t -> hPutBuilder stdout (encode t)
      | otherwise -> hPutStrLn stderr "usage: toml (decode|encode) < input" >> exitWith (ExitFailure 2)

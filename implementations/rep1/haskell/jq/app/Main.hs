-- | Command-line interface: the first stdin line is the filter, the rest is
-- the JSON document; every result is printed as compact JSON.
module Main (main) where

import qualified Data.ByteString as B
import Data.ByteString.Builder (hPutBuilder, char7, string7)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Jq
import System.Exit (exitWith, ExitCode (..))
import System.IO

main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout (BlockBuffering Nothing)
  input <- B.getContents
  let (filterLine, rest) = B.break (== 10) input
      doc = B.drop 1 rest
  case (parseFilter (TE.decodeUtf8With TE.lenientDecode filterLine), parseJson doc) of
    (Left e, _) -> failWith ("filter: " ++ e)
    (_, Left e) -> failWith ("input: " ++ e)
    (Right f, Right v) -> do
      mapM_ emit (runFilter f v)
      hFlush stdout
  where
    emit (Right x) = hPutBuilder stdout (renderValue x <> char7 '\n')
    emit (Left _) = hPutBuilder stdout (string7 "error\n")
    failWith msg = hPutStrLn stderr msg >> exitWith (ExitFailure 2)

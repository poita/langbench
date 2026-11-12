-- | The command-line tool: read a module stream on stdin, compile it and run
-- it (SPEC.md section 1).
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.IO

import Langvm

main :: IO ()
main = do
  hSetBinaryMode stdin True
  bytes <- BS.getContents
  let input = T.unpack (TE.decodeUtf8With TE.lenientDecode bytes)
  hSetEncoding stdout utf8
  hSetNewlineMode stdout noNewlineTranslation
  hSetBuffering stdout (BlockBuffering (Just 65536))
  result <- runSource input (hPutStr stdout)
  case result of
    Left d -> putStrLn (renderDiagnostic d)
    Right Finished -> return ()
    Right (Panicked msg) -> putStrLn ("panic: " ++ msg)
  hFlush stdout

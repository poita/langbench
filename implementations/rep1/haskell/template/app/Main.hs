-- | Command-line tool: reads a document (JSON context, @--@, named
-- templates) on stdin and prints the rendering of the first template, or
-- @error: <kind>@.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

import Template (renderDocument)

main :: IO ()
main = do
  input <- TE.decodeUtf8With TE.lenientDecode <$> BS.getContents
  result <- renderDocument input
  case result of
    Right out -> BS.putStr (TE.encodeUtf8 out)
    Left msg -> do
      hPutStrLn stderr ("template: " ++ msg)
      exitWith (ExitFailure 2)

-- | Command-line tool: @kvstore <input dir> <output dir>@ (SPEC §2).
module Main (main) where

import qualified Data.ByteString as BS
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getArgs, getProgName)
import System.Exit (exitWith, ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import Tessera.Script (ScriptResult (..), runScript)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, output] -> run input output
    _ -> do
      name <- getProgName
      hPutStrLn stderr ("usage: " ++ name ++ " <input dir> <output dir>")
      exitWith (ExitFailure 2)

readOptional :: FilePath -> IO (Maybe BS.ByteString)
readOptional path = do
  exists <- doesFileExist path
  if exists then Just <$> BS.readFile path else pure Nothing

run :: FilePath -> FilePath -> IO ()
run input output = do
  commands <- BS.readFile (input </> "commands.txt")
  tdb <- readOptional (input </> "main.tdb")
  twal <- readOptional (input </> "main.twal")
  result <- runScript tdb twal commands
  createDirectoryIfMissing True output
  BS.writeFile (output </> "results.txt") (resultsText result)
  BS.writeFile (output </> "main.tdb") (resultsDatabase result)
  BS.writeFile (output </> "main.twal") (resultsLog result)

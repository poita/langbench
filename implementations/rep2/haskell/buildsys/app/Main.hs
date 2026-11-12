-- | Command-line driver: @buildsys <input directory> <output directory>@.
module Main (main) where

import qualified Data.ByteString as B
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Kiln.Session (parseSession, runSession)
import Kiln.Workspace.IO (loadDirectory, writeDirectory)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, output] -> run input output
    _ -> hPutStrLn stderr "usage: buildsys <input directory> <output directory>" >> exitFailure

run :: FilePath -> FilePath -> IO ()
run input output = do
  (ws, session) <- loadDirectory input
  let steps = maybe [] parseSession session
      (logText, final) = runSession ws steps
  createDirectoryIfMissing True output
  B.writeFile (output </> "log.txt") logText
  createDirectoryIfMissing True (output </> "workspace")
  writeDirectory (output </> "workspace") final

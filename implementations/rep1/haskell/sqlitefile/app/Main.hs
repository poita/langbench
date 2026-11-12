-- | Command-line front end: @sqlitefile <input dir> <output dir>@.
--
-- Reads the single @*.sqlite@ file and @queries.txt@ from the input
-- directory and writes @NNN.txt@ per query into the output directory. Exits 0
-- even if individual queries fail; a failing query's file contains @error@.
module Main (main) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B
import Data.List (isSuffixOf, sort)
import SqliteFile
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [inDir, outDir] -> run inDir outDir
    _ -> hPutStrLn stderr "usage: sqlitefile <input dir> <output dir>" >> exitWith (ExitFailure 2)

run :: FilePath -> FilePath -> IO ()
run inDir outDir = do
  files <- listDirectory inDir
  queriesRaw <- BS.readFile (inDir </> "queries.txt")
  let queries = splitLines queriesRaw
      dbFiles = sort (filter (".sqlite" `isSuffixOf`) files)
  session <- case dbFiles of
    (f : _) -> do
      r <- try (BS.readFile (inDir </> f) >>= openSession) :: IO (Either SomeException (Either SqliteError Session))
      pure (either (const Nothing) (either (const Nothing) Just) r)
    [] -> pure Nothing
  mapM_
    ( \(n, q) -> do
        out <- answer session q
        BS.writeFile (outDir </> pad3 n ++ ".txt") out
    )
    (zip [1 :: Int ..] queries)

answer :: Maybe Session -> BS.ByteString -> IO BS.ByteString
answer Nothing _ = pure errorOutput
answer (Just s) q = do
  r <- try (runQuery s q) :: IO (Either SomeException (Either SqliteError BS.ByteString))
  pure $ case r of
    Right (Right out) -> out
    _ -> errorOutput

errorOutput :: BS.ByteString
errorOutput = B.pack "error\n"

-- Lines of the queries file; a final newline does not start a new line.
splitLines :: BS.ByteString -> [BS.ByteString]
splitLines s = case B.split '\n' s of
  xs | not (null xs) && B.null (last xs) -> init xs
     | otherwise -> xs

pad3 :: Int -> String
pad3 n = let s = show n in replicate (3 - length s) '0' ++ s

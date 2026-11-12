{-# LANGUAGE OverloadedStrings #-}
-- | Command-line tool: @fulltext <input directory> <output directory>@.
--
-- Reads @docs/*.txt@ and @queries.txt@ from the input directory and writes
-- @results.txt@ and @stats.txt@ into the output directory.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Fulltext
import Fulltext.Corpus
import Fulltext.Report

main :: IO ()
main = do
  args <- getArgs
  case args of
    [input, output] -> run input output
    _ -> do
      hPutStrLn stderr "usage: fulltext <input directory> <output directory>"
      exitWith (ExitFailure 2)

run :: FilePath -> FilePath -> IO ()
run input output = do
  docs <- loadDocuments input
  let ix = buildIndex docs
  queries <- parseQueryFile . TE.decodeUtf8 <$> B.readFile (input </> "queries.txt")
  let answered = [ (job, runQuery ix (jobLimit job) (jobText job)) | job <- queries ]
  createDirectoryIfMissing True output
  B.writeFile (output </> "results.txt") (TE.encodeUtf8 (renderResults answered))
  B.writeFile (output </> "stats.txt") (TE.encodeUtf8 (renderStats ix))

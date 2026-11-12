-- |
-- Module      : Git.Batch
-- Description : Running a file of commands against a repository.
module Git.Batch
  ( runBatch
  , splitCommands
  , outputName
  , answer
  ) where

import Control.Exception (SomeException, evaluate, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Git.Command
import Git.Store (Repository, openRepository)

-- | The lines of a command file (LF separated; a final newline is optional).
splitCommands :: ByteString -> [ByteString]
splitCommands bs
  | BS.null bs = []
  | otherwise =
      let ls = BS.split 10 bs
       in if BS.null (last ls) then init ls else ls

-- | The output file name for the command on line @k@ (1-based): @001.out@ ...
outputName :: Int -> FilePath
outputName k = let s = show k in replicate (3 - length s) '0' ++ s ++ ".out"

-- | The bytes a command line produces: its answer, or @error\\n@ if it fails
-- for any reason.
answer :: Repository -> ByteString -> IO ByteString
answer repo line = do
  r <- try $ case parseCommand line of
    Left e -> ioError (userError e)
    Right cmd -> runCommand repo cmd >>= evaluate
  pure (either (\e -> const (BC.pack "error\n") (e :: SomeException)) id r)

-- | @runBatch input out@: @input@ holds @repo/@ and @commands.txt@; one
-- @NNN.out@ per command is written into @out@.
runBatch :: FilePath -> FilePath -> IO ()
runBatch input out = do
  repo <- openRepository (input </> "repo")
  cmds <- splitCommands <$> BS.readFile (input </> "commands.txt")
  createDirectoryIfMissing True out
  mapM_
    (\(k, line) -> answer repo line >>= BS.writeFile (out </> outputName k))
    (zip [1 ..] cmds)

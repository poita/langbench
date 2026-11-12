-- | Execution of a command script against a directory of Matrix Market files.
module Linalg.Runner
  ( Command (..)
  , parseScript
  , runDirectory
  ) where

import Control.Exception (SomeException, evaluate, try)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as C
import Data.Char (isSpace)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr, IOMode (WriteMode), withBinaryFile)
import Text.Printf (printf)

import Linalg.Error (errorCode)
import Linalg.Matrix (Matrix)
import Linalg.MatrixMarket (readMatrixFile, writeMatrixFile)
import Linalg.Operation (Operation, arity, execute, operationName, parseOperation)

-- | One command line: an operation and its matrix file names.
data Command = Command
  { commandOperation :: Operation
  , commandArguments :: [FilePath]
  }
  deriving (Eq, Show)

-- | Parse a script. Blank lines and @#@ comment lines are dropped (and do not
-- count); every remaining line yields either a 'Command' or a message
-- describing why the line is malformed. The position in the result list is
-- the command number minus one.
parseScript :: String -> [Either String Command]
parseScript = map parseLine . filter keep . map strip . lines
  where
    strip = dropWhile blank . reverse . dropWhile blank . reverse
    blank c = c == ' ' || c == '\t' || isSpace c
    keep l = take 1 l /= "" && take 1 l /= "#"
    parseLine l = case words l of
      [] -> Left "empty command"
      (name : args) -> case parseOperation name of
        Nothing -> Left ("unknown operation " ++ show name)
        Just op
          | length args /= arity op ->
              Left (operationName op ++ " expects " ++ show (arity op) ++ " argument(s)")
          | otherwise -> Right (Command op args)

-- | @runDirectory input output@ executes @input/commands.txt@ and writes one
-- result file (or @NNN_error.txt@) per operation into @output@. Commands that
-- cannot even be started (unknown operation, unreadable matrix) are reported
-- on stderr and produce no files; the remaining commands still run.
runDirectory :: FilePath -> FilePath -> IO ()
runDirectory inDir outDir = do
  script <- C.unpack <$> C.readFile (inDir </> "commands.txt")
  cache <- newIORef Map.empty
  mapM_ (runOne cache) (zip [1 :: Int ..] (parseScript script))
  where
    runOne _ (n, Left msg) = hPutStrLn stderr ("command " ++ show n ++ ": " ++ msg)
    runOne cache (n, Right (Command op args)) = do
      r <- try $ do
        mats <- mapM (load cache) args
        case execute op mats of
          Left e -> writeText (name n "error.txt") (errorCode e ++ "\n")
          Right results -> mapM_ (\(sfx, m) -> writeMatrixFile (name n (sfx ++ ".mtx")) m) results
      case r of
        Left ex -> hPutStrLn stderr ("command " ++ show n ++ ": " ++ show (ex :: SomeException))
        Right () -> pure ()
    name n rest = outDir </> (printf "%03d_" n ++ rest)
    writeText path txt = withBinaryFile path WriteMode (\h -> BB.hPutBuilder h (BB.stringUtf8 txt))
    load :: IORef (Map.Map FilePath Matrix) -> FilePath -> IO Matrix
    load cache f = do
      m <- Map.lookup f <$> readIORef cache
      case m of
        Just x -> pure x
        Nothing -> do
          r <- readMatrixFile (inDir </> f)
          x <- either (ioError . userError . ((f ++ ": ") ++)) evaluate r
          modifyIORef' cache (Map.insert f x)
          pure x

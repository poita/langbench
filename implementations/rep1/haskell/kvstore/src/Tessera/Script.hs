-- | Running a command script: the engine behind the command-line tool.
module Tessera.Script
  ( ScriptResult (..)
  , commandLines
  , runScript
  , runLine
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as LBS
import Tessera.Exec (execute)
import Tessera.Parser (parseCommand)
import Tessera.Render (renderBlock)
import Tessera.Store

-- | The three output files of a run.
data ScriptResult = ScriptResult
  { resultsText :: BS.ByteString
  -- ^ @results.txt@
  , resultsDatabase :: BS.ByteString
  -- ^ @main.tdb@
  , resultsLog :: BS.ByteString
  -- ^ @main.twal@
  }

-- | Split @commands.txt@ into lines: LF separates them and a final LF
-- terminates the last one (SPEC §2.1).
commandLines :: BS.ByteString -> [BS.ByteString]
commandLines bs = case BS.split 10 bs of
  parts | not (BS.null bs) && BS.last bs == 10 -> init parts
        | otherwise -> parts

-- | Run one line against a store and render its result block.
runLine :: Store -> Int -> BS.ByteString -> IO B.Builder
runLine db k line = case parseCommand line of
  Left e -> pure (renderBlock k (Left e))
  Right c -> renderBlock k <$> execute db c

-- | Run a whole script against a database given as optional @main.tdb@ and
-- @main.twal@ contents.  An explicit transaction still open at the end is
-- rolled back (SPEC §2.3).
runScript :: Maybe BS.ByteString -> Maybe BS.ByteString -> BS.ByteString -> IO ScriptResult
runScript tdb twal commands = do
  db <- openStore tdb twal
  blocks <- mapM (uncurry (runLine db)) (zip [1 ..] (commandLines commands))
  closeStore db
  ScriptResult (LBS.toStrict (B.toLazyByteString (mconcat blocks)))
    <$> storeFileBytes db
    <*> storeLogBytes db

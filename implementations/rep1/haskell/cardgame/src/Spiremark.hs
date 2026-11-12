-- |
-- Module      : Spiremark
-- Description : Public API of the Spiremark rules engine.
--
-- Spiremark is an invented two-player duelling-card game.  This library
-- implements its complete rules engine: it reads a card database, sets up a
-- match, and simulates a script of player actions, producing a deterministic
-- event log.
--
-- The simplest entry point is 'runMatchText', which takes the text of a match
-- file and returns the output lines:
--
-- > import Spiremark
-- >
-- > main :: IO ()
-- > main = do
-- >   out <- runMatchText "CARDS data/cards.spire\nSEED 1\nSTART\nDUMP\n"
-- >   mapM_ putStrLn out
--
-- For finer control use the pieces directly: 'parseMatch' and 'loadDatabase'
-- produce a 'Setup' and a 'CardDb', 'newGame' builds a 'Game', and 'stepLine'
-- feeds it script lines one at a time.
module Spiremark
  ( -- * Running a match
    runMatchText
  , simulate
  , Fatal (..)
  , fatalLine
    -- * Building blocks
  , module Spiremark.Match
  , module Spiremark.Types
  , CardDb
  , Card (..)
  , loadDatabase
  , parseDatabase
  , cardBlock
  , Game
  , newGame
  , stepLine
  , finishGame
  , takeOutput
  , gameOver
  , gameResult
  , SetupError (..)
  ) where

import Spiremark.Card.Parse (loadDatabase, parseDatabase)
import Spiremark.Card.Print (cardBlock)
import Spiremark.Card.Types (Card (..), CardDb)
import Spiremark.Engine
import Spiremark.Match
import Spiremark.Types

-- | The three fatal setup outcomes (SPEC.md section 8).
data Fatal = BadSetup | BadDatabase | UnknownCardFatal
  deriving (Eq, Show)

-- | The single output line of a fatal outcome.
fatalLine :: Fatal -> String
fatalLine BadSetup = "FATAL bad-setup"
fatalLine BadDatabase = "FATAL bad-database"
fatalLine UnknownCardFatal = "FATAL unknown-card"

-- | Simulate a parsed match against an already-loaded database.  The result is
-- the full list of output lines, produced lazily one script line at a time.
simulate :: Setup -> CardDb -> [(Int, String)] -> Either Fatal [String]
simulate su db script = case newGame su db of
  Left UnknownCard -> Left UnknownCardFatal
  Right g0 -> Right (go g0 script)
  where
    go g [] =
      let (out, _) = takeOutput (finishGame g) in out
    go g ((n, l) : rest)
      | isBlank l = go g rest
      | otherwise =
          let (out, g') = takeOutput g
              g'' = stepLine n (parseScriptLine l) g'
           in out ++ go g'' rest
    isBlank l = case dropWhile (`elem` " \t") l of
      [] -> True
      ('#' : _) -> True
      _ -> False

-- | Run a whole match file.  The card database named by the @CARDS@ line is
-- read from the file system (relative paths against the current directory).
runMatchText :: String -> IO [String]
runMatchText input = case parseMatch input of
  Left () -> return [fatalLine BadSetup]
  Right (su, script) -> do
    mdb <- loadDatabase (suCards su)
    return $ case mdb of
      Nothing -> [fatalLine BadDatabase]
      Just db -> either (\f -> [fatalLine f]) id (simulate su db script)

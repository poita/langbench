-- |
-- Module      : OrderBook
-- Description : A single-instrument limit order book with price-time priority.
--
-- = Overview
--
-- The library is organised by responsibility:
--
--   * "OrderBook.Types"  – commands, events and basic value types;
--   * "OrderBook.Book"   – the persistent book data structure;
--   * "OrderBook.Engine" – matching rules ('execute', 'run');
--   * "OrderBook.Parse"  – parsing the textual command format;
--   * "OrderBook.Render" – rendering events as text.
--
-- This module re-exports what most users need.
--
-- = Example
--
-- > import OrderBook
-- > import qualified Data.ByteString.Char8 as C
-- >
-- > main :: IO ()
-- > main = do
-- >   let cmds = [ Limit (C.pack "s1") Sell 101 5 GoodTillCancel
-- >              , Limit (C.pack "b1") Buy  102 3 GoodTillCancel
-- >              , Snapshot ]
-- >   mapM_ print (run cmds)
--
-- prints @Rest "s1"@, @Trade "b1" "s1" 101 3@, @Filled "b1"@,
-- @AskLevel 101 2 1@ and @EndOfBook@.
module OrderBook
  ( module OrderBook.Types
  , Book
  , emptyBook
  , execute
  , run
  , runFrom
  , parseCommand
  , parseCommands
  , renderEvent
  , renderEvents
  , processInput
  ) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as C

import OrderBook.Book (Book)
import qualified OrderBook.Book as Book
import OrderBook.Engine
import OrderBook.Parse
import OrderBook.Render
import OrderBook.Types

-- | The empty book.
emptyBook :: Book
emptyBook = Book.empty

-- | Process a complete textual input (count line plus commands) and return
-- the textual output. This is exactly what the command-line tool does.
processInput :: C.ByteString -> BB.Builder
processInput = renderEvents . run . parseCommands

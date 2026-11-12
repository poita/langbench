-- | Tessera: an embedded, single-file transactional document store with a
-- write-ahead log, a B+tree primary index, overflow pages, secondary indexes,
-- crash recovery, checkpointing and a small command language.
--
-- This module re-exports the types you need; the operations live in
-- "Tessera.Store" and are meant to be imported qualified:
--
-- > import Tessera
-- > import qualified Tessera.Store as Store
-- >
-- > main :: IO ()
-- > main = do
-- >   db <- Store.newStore
-- >   Right doc <- pure (parseValue "{name:\"ada\",age:36}")
-- >   _ <- Store.put db "u1" doc
-- >   Store.get db "u1" >>= print
module Tessera
  ( -- * Stores and values
    Store
  , Value (..)
  , ErrorKind (..)
  , errorName
  , Path
  , parsePath
  , pathText
  , parseValue
  , render
    -- * Running command scripts
  , ScriptResult (..)
  , runScript
  , parseCommand
  , Command (..)
    -- * Opening
  , openStore
  , newStore
  ) where

import Tessera.Command (Command (..))
import Tessera.Error (ErrorKind (..), errorName)
import Tessera.Parser (parseCommand, parseValue)
import Tessera.Path (Path, parsePath, pathText)
import Tessera.Script (ScriptResult (..), runScript)
import Tessera.Store (Store, newStore, openStore)
import Tessera.Value (Value (..), render)

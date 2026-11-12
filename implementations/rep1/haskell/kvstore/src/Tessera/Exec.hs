-- | Execution of parsed commands against a store (SPEC §18.3, §19).
module Tessera.Exec
  ( Reply (..)
  , execute
  ) where

import qualified Data.ByteString as BS
import Tessera.Command
import Tessera.Error (ErrorKind)
import Tessera.Path (Path)
import Tessera.Query (Plan)
import Tessera.Store (IndexInfo, PutOutcome (..), Stat, Store)
import qualified Tessera.Store as Store
import Tessera.Value (Value)

-- | The successful result of a command.
data Reply
  = RBegin
  | RCommit Int Int
  | RRollback
  | RCheckpoint Int
  | RPut PutOutcome
  | RGet Value
  | RDelete
  | RUpdate
  | RUnset
  | RScan [(BS.ByteString, Maybe Value)]
  | RFind Plan [(BS.ByteString, Value)]
  | RCreateIndex Path Int
  | RDropIndex Path Int
  | RIndexes [IndexInfo]
  | RStat Stat

-- | Run one command.
execute :: Store -> Command -> IO (Either ErrorKind Reply)
execute db cmd = case cmd of
  Begin -> (RBegin <$) <$> Store.begin db
  Commit -> fmap (uncurry RCommit) <$> Store.commit db
  Rollback -> (RRollback <$) <$> Store.rollback db
  Checkpoint -> fmap RCheckpoint <$> Store.checkpoint db
  Stat -> Right . RStat <$> Store.stat db
  Indexes -> Right . RIndexes <$> Store.indexes db
  Put k v -> fmap RPut <$> Store.put db k v
  Get k -> fmap RGet <$> Store.get db k
  Delete k -> (RDelete <$) <$> Store.delete db k
  Update k p v -> (RUpdate <$) <$> Store.update db k p v
  Unset k p -> (RUnset <$) <$> Store.unset db k p
  Scan o -> fmap RScan <$> Store.scan db o
  Find p l -> fmap (uncurry RFind) <$> Store.find db p l
  CreateIndex p -> fmap (RCreateIndex p) <$> Store.createIndex db p
  DropIndex p -> fmap (RDropIndex p) <$> Store.dropIndex db p

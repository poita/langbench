-- | The abstract syntax of the command language (SPEC §6.5).
module Tessera.Command
  ( Command (..)
  ) where

import qualified Data.ByteString as BS
import Tessera.Path (Path)
import Tessera.Query (Pred, ScanOptions)
import Tessera.Value (Value)

-- | One parsed command line.
data Command
  = Begin
  | Commit
  | Rollback
  | Checkpoint
  | Stat
  | Indexes
  | Put BS.ByteString Value
  | Get BS.ByteString
  | Delete BS.ByteString
  | Update BS.ByteString Path Value
  | Unset BS.ByteString Path
  | Scan ScanOptions
  | Find Pred (Maybe Int)
  | CreateIndex Path
  | DropIndex Path
  deriving (Eq, Show)

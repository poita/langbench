-- | Read SQLite 3 database files directly, without SQLite.
--
-- >>> bytes <- Data.ByteString.readFile "people.sqlite"
-- >>> let Right session = openSession bytes
-- >>> runQuery session (Data.ByteString.Char8.pack "SELECT name FROM people")
-- Right "Ada\nGrace\n"
--
-- The layers, bottom to top:
--
-- * "SqliteFile.Pager" – header, pages, cell payloads and overflow chains
-- * "SqliteFile.BTree" – table and index B-tree traversal
-- * "SqliteFile.Record" – record (row) decoding
-- * "SqliteFile.DDL" and "SqliteFile.Catalog" – the schema
-- * "SqliteFile.Query" and "SqliteFile.Exec" – the query language
module SqliteFile
  ( Session (..)
  , openSession
  , runQuery
  , SqliteError (..)
    -- * Re-exports
  , Value (..)
  , Command
  , parseCommand
  ) where

import Control.Exception (evaluate, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import SqliteFile.Catalog (Catalog, catRows, loadCatalog)
import SqliteFile.Error (SqliteError (..))
import SqliteFile.Exec (execute, renderRows)
import SqliteFile.Pager (Database, openDatabase)
import SqliteFile.Query (Command, parseCommand)
import SqliteFile.Value (Value (..))

-- | An opened database together with its schema catalog.
data Session = Session
  { sessionDb :: Database
  , sessionCatalog :: Catalog
  }

-- | Open a database from the complete contents of the file. The schema is
-- read once here and shared by every query.
openSession :: ByteString -> IO (Either SqliteError Session)
openSession bytes = case openDatabase bytes of
  Left msg -> pure (Left (CorruptDatabase msg))
  Right db -> do
    let cat = loadCatalog db
    -- Force the schema rows now so a corrupt schema is reported here.
    r <- try (evaluate (length (catRows cat)))
    pure $ case r of
      Left e -> Left e
      Right _ -> Right (Session db cat)

-- | Run one query line and return the text of its result file (every row
-- newline-terminated; empty when there are no rows).
--
-- Fails with 'QueryError' for a malformed query or an unknown name, and with
-- 'CorruptDatabase' if the file turns out to be malformed.
runQuery :: Session -> ByteString -> IO (Either SqliteError ByteString)
runQuery (Session db cat) line =
  case parseCommand line of
    Nothing -> pure (Left (QueryError "malformed query"))
    Just cmd ->
      try (evaluate (BL.toStrict (BB.toLazyByteString (renderRows (execute db cat cmd)))))

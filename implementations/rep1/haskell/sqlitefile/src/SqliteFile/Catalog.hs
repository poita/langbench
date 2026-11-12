-- | The schema catalog: the rows of @sqlite_schema@ and the tables and
-- indexes parsed from them.
module SqliteFile.Catalog
  ( SchemaRow (..)
  , Column (..)
  , Table (..)
  , Index (..)
  , Catalog (..)
  , loadCatalog
  , lookupTable
  , lookupIndex
  , columnValues
  ) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import SqliteFile.BTree (tableRows)
import SqliteFile.DDL
import SqliteFile.Pager (Database)
import SqliteFile.Record (decodeRecord)
import SqliteFile.Value

-- | One row of @sqlite_schema@.
data SchemaRow = SchemaRow
  { srType :: ByteString
  , srName :: ByteString
  , srTblName :: ByteString
  , srRootPage :: Int
  , srSql :: Maybe ByteString
  }
  deriving (Eq, Show)

-- | A table column with its derived affinity.
data Column = Column
  { colName :: ByteString
  , colAffinity :: Affinity
  }
  deriving (Eq, Show)

-- | A rowid table.
data Table = Table
  { tableName :: ByteString
  , tableRoot :: Int
  , tableColumns :: [Column]
  , tableRowidAlias :: Maybe Int
  }
  deriving (Eq, Show)

-- | An index created by @CREATE INDEX@.
data Index = Index
  { indexName :: ByteString
  , indexTable :: ByteString
  , indexRoot :: Int
  , indexColumns :: [ByteString]
  }
  deriving (Eq, Show)

-- | Everything learned from @sqlite_schema@.
data Catalog = Catalog
  { catRows :: [SchemaRow]
  -- ^ every schema row, in rowid (schema) order
  , catTables :: M.Map ByteString Table
  -- ^ keyed by lower-cased name
  , catIndexes :: M.Map ByteString Index
  -- ^ keyed by lower-cased name
  }

-- | Read @sqlite_schema@ (page 1) once and parse every table and index.
loadCatalog :: Database -> Catalog
loadCatalog db = Catalog rows tables indexes
  where
    rows = mapMaybe (schemaRow . decodeRecord . snd) (tableRows db 1)
    tables =
      M.fromList
        [ (lowerAscii (srName r), mkTable r def)
        | r <- rows
        , srType r == bs "table"
        , Just sql <- [srSql r]
        , Just def <- [parseCreateTable sql]
        ]
    indexes =
      M.fromList
        [ (lowerAscii (srName r), Index (srName r) (idTable def) (srRootPage r) (idColumns def))
        | r <- rows
        , srType r == bs "index"
        , Just sql <- [srSql r]
        , Just def <- [parseCreateIndex sql]
        ]
    mkTable r def =
      Table
        { tableName = srName r
        , tableRoot = srRootPage r
        , tableColumns = [Column (cdName c) (affinityOf (cdType c)) | c <- tdColumns def]
        , tableRowidAlias = tdRowidAlias def
        }
    bs = B.pack

schemaRow :: [Value] -> Maybe SchemaRow
schemaRow (VText ty : VText name : VText tbl : root : rest) =
  Just
    SchemaRow
      { srType = ty
      , srName = name
      , srTblName = tbl
      , srRootPage = case root of VInt n -> fromIntegral n; _ -> 0
      , srSql = case rest of (VText s : _) -> Just s; _ -> Nothing
      }
schemaRow _ = Nothing

-- | Look up a table by name (ASCII case-insensitive).
lookupTable :: Catalog -> ByteString -> Maybe Table
lookupTable cat n = M.lookup (lowerAscii n) (catTables cat)

-- | Look up an index by name (ASCII case-insensitive).
lookupIndex :: Catalog -> ByteString -> Maybe Index
lookupIndex cat n = M.lookup (lowerAscii n) (catIndexes cat)

-- | The values of a row in declared column order. A missing trailing column
-- reads as NULL, the rowid-alias column is the rowid, and integers in
-- REAL-affinity columns are widened to reals. Lazy in the record.
columnValues :: Table -> Int64 -> ByteString -> [Value]
columnValues t rowid payload = zipWith3 fixup [0 ..] (tableColumns t) (decodeRecord payload ++ repeat VNull)
  where
    fixup :: Int -> Column -> Value -> Value
    fixup i c v
      | Just i == tableRowidAlias t = VInt rowid
      | colAffinity c == AffReal, VInt n <- v = VReal (fromIntegral n)
      | otherwise = v

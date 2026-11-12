-- | The database header, page access, B-tree page headers and cell payloads
-- (including overflow chains).
module SqliteFile.Pager
  ( Database (..)
  , openDatabase
  , PageKind (..)
  , Page (..)
  , readPage
  , isInterior
  , cellOffset
  , cellPayload
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B
import SqliteFile.Error (corrupt)
import SqliteFile.Varint (getBE)

-- | An opened database: the whole file in memory plus its geometry.
data Database = Database
  { dbBytes :: !ByteString
  , dbPageSize :: !Int
  , dbUsable :: !Int
  -- ^ usable size @U@ = page size minus reserved bytes
  , dbPageCount :: !Int
  -- ^ number of pages actually present in the file
  }

-- | Validate the header and wrap the file contents.
openDatabase :: ByteString -> Either String Database
openDatabase bs
  | BS.length bs < 100 = Left "file too short to be a database"
  | BS.take 16 bs /= B.pack "SQLite format 3\0" = Left "not a SQLite 3 database"
  | pageSize < 512 || pageSize > 65536 = Left "invalid page size"
  | usable < 480 = Left "invalid reserved size"
  | otherwise = Right (Database bs pageSize usable (BS.length bs `div` pageSize))
  where
    raw = getBE bs 16 2
    pageSize = if raw == 1 then 65536 else raw
    usable = pageSize - getBE bs 20 1

-- | The four B-tree page types.
data PageKind = InteriorIndex | InteriorTable | LeafIndex | LeafTable
  deriving (Eq, Show)

-- | A decoded B-tree page header with the page bytes.
data Page = Page
  { pageBytes :: !ByteString
  , pageKind :: !PageKind
  , pageCells :: !Int
  -- ^ number of cells
  , pageRightChild :: !Int
  -- ^ right-most child (interior pages only, else 0)
  , pageArray :: !Int
  -- ^ offset of the cell pointer array
  }

isInterior :: PageKind -> Bool
isInterior k = k == InteriorIndex || k == InteriorTable

-- | Load page @n@ (1-based) and decode its header.
readPage :: Database -> Int -> Page
readPage db n
  | n < 1 || n > dbPageCount db = corrupt ("page number out of range: " ++ show n)
  | otherwise =
      let pg = BS.take (dbPageSize db) (BS.drop ((n - 1) * dbPageSize db) (dbBytes db))
          base = if n == 1 then 100 else 0
          kind = case BS.index pg base of
            0x02 -> InteriorIndex
            0x05 -> InteriorTable
            0x0a -> LeafIndex
            0x0d -> LeafTable
            t -> corrupt ("bad B-tree page type " ++ show t ++ " on page " ++ show n)
          interior = kind == InteriorIndex || kind == InteriorTable
       in Page
            { pageBytes = pg
            , pageKind = kind
            , pageCells = getBE pg (base + 3) 2
            , pageRightChild = if interior then getBE pg (base + 8) 4 else 0
            , pageArray = base + (if interior then 12 else 8)
            }

-- | Offset of cell @i@ within the page.
cellOffset :: Page -> Int -> Int
cellOffset p i = getBE (pageBytes p) (pageArray p + 2 * i) 2

-- | Assemble a cell's payload: the local bytes starting at @start@ on the
-- page, followed by the overflow chain when the payload does not fit.
--
-- Arguments: the database, the page, the offset where the payload starts
-- (just after the size varints), and the total payload size @P@.
cellPayload :: Database -> Page -> Int -> Int -> ByteString
cellPayload db p start total
  | total < 0 = corrupt "negative payload size"
  | total <= x = slice start total
  | otherwise =
      let localSize = if k <= x then k else m
          local = slice start localSize
          firstOverflow = getBE pg (start + localSize) 4
       in BS.concat (local : overflow firstOverflow (total - localSize) (dbPageCount db))
  where
    pg = pageBytes p
    u = dbUsable db
    m = ((u - 12) * 32) `div` 255 - 23
    x | pageKind p == LeafTable = u - 35
      | otherwise = ((u - 12) * 64) `div` 255 - 23
    k = m + ((total - m) `mod` (u - 4))
    slice off len
      | off < 0 || off + len > BS.length pg = corrupt "cell payload extends past its page"
      | otherwise = BS.take len (BS.drop off pg)
    overflow _ remaining _ | remaining <= 0 = []
    overflow _ _ 0 = corrupt "overflow chain too long"
    overflow pgno remaining budget
      | pgno == 0 = corrupt "overflow chain ends early"
      | pgno > dbPageCount db = corrupt "overflow page out of range"
      | otherwise =
          let page = BS.take (dbPageSize db) (BS.drop ((pgno - 1) * dbPageSize db) (dbBytes db))
              next = getBE page 0 4
              n = min remaining (u - 4)
           in BS.take n (BS.drop 4 page) : overflow next (remaining - n) (budget - 1 :: Int)


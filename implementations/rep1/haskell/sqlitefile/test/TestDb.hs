-- | A tiny SQLite file writer used only to build fixtures for the tests.
module TestDb
  ( fixtureDb
  , blobPayload
  , encodeVarint
  , encodeRecord
  ) where

import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.Word (Word8)
import GHC.Float (castDoubleToWord64)
import SqliteFile (Value (..))

pageSize :: Int
pageSize = 512

be :: Int -> Int -> [Word8]
be n x = [fromIntegral (x `shiftR` (8 * i)) | i <- [n - 1, n - 2 .. 0]]

-- | Encode a non-negative or negative 64-bit value as a SQLite varint.
encodeVarint :: Int64 -> ByteString
encodeVarint v
  | v < 0 || w >= 2 ^ (56 :: Int) =
      BS.pack ([fromIntegral (0x80 .|. ((w `shiftR` (8 + 7 * (7 - i))) .&. 0x7f)) | i <- [0 .. 7]] ++ [fromIntegral (w .&. 0xff)])
  | otherwise =
      let groups = reverse (takeWhile (> 0) (iterate (`shiftR` 7) w))
          gs = if null groups then [0] else groups
          n = length gs
       in BS.pack [fromIntegral ((g .&. 0x7f) .|. (if i < n - 1 then 0x80 else 0)) | (i, g) <- zip [0 :: Int ..] gs]
  where
    w = fromIntegral v :: Integer

-- | Encode a record. Integers use the smallest fitting serial type.
encodeRecord :: [Value] -> ByteString
encodeRecord vals =
  let cols = map col vals
      hdrBody = BS.concat (map (\(st, _) -> encodeVarint st) cols)
      hdrLen = BS.length hdrBody + 1 -- header sizes in these tests stay below 128
   in BS.concat (BS.singleton (fromIntegral hdrLen) : hdrBody : map snd cols)
  where
    col v = case v of
      VNull -> (0, BS.empty)
      VInt 0 -> (8, BS.empty)
      VInt 1 -> (9, BS.empty)
      VInt i
        | i >= -128 && i < 128 -> (1, BS.pack (be 1 (fromIntegral i)))
        | i >= -32768 && i < 32768 -> (2, BS.pack (be 2 (fromIntegral i)))
        | otherwise -> (6, BS.pack (be 8 (fromIntegral i)))
      VReal d -> (7, BS.pack (be 8 (fromIntegral (castDoubleToWord64 d))))
      VText t -> (13 + 2 * fromIntegral (BS.length t), t)
      VBlob b -> (12 + 2 * fromIntegral (BS.length b), b)

pad :: ByteString -> ByteString
pad b = b <> BS.replicate (pageSize - BS.length b) 0

-- Assemble a b-tree page from its type byte, optional right child and cells.
btreePage :: Bool -> Word8 -> Maybe Int -> [ByteString] -> ByteString
btreePage isFirst ty right cells =
  let base = if isFirst then 100 else 0
      hdrLen = if right == Nothing then 8 else 12
      arrayEnd = base + hdrLen + 2 * length cells
      offsets = scanl (\o c -> o - BS.length c) pageSize cells
      cellOffs = tail' offsets
      tail' = drop 1
      hdr =
        BS.pack ([ty] ++ be 2 0 ++ be 2 (length cells) ++ be 2 (last offsets) ++ [0] ++ maybe [] (be 4) right)
      ptrs = BS.pack (concatMap (be 2) cellOffs)
      body = hdr <> ptrs
      gap = BS.replicate (last offsets - arrayEnd) 0
      content = BS.concat (reverse cells)
   in BS.replicate base 0 <> body <> gap <> content

leafTableCell :: Int64 -> ByteString -> ByteString
leafTableCell rowid payload = encodeVarint (fromIntegral (BS.length payload)) <> encodeVarint rowid <> payload

-- | A 1000-byte payload (forces overflow on 512-byte pages) built from a
-- repeating pattern.
blobPayload :: ByteString
blobPayload = BS.pack (take 1000 (cycle [0 .. 250]))

-- | A 512-byte-page database with several tables:
--
-- * @people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, height REAL)@
--   with index @people_age@ (page 2 and 3);
-- * @blobs(id INTEGER PRIMARY KEY, data BLOB)@ with one overflowing row
--   (pages 4 to 6);
-- * @deep(n INTEGER PRIMARY KEY, v TEXT)@ as a two-level B-tree (pages 7 to 9).
fixtureDb :: ByteString
fixtureDb = BS.concat [pad' page1, p2, p3, p4, p5, p6, p7, p8, p9]
  where
    pad' = id
    t = VText . B.pack
    schemaRow rowid ty name tbl root sql =
      leafTableCell rowid (encodeRecord [t ty, t name, t tbl, VInt root, maybe VNull t sql])
    schemaCells =
      [ schemaRow 1 "table" "people" "people" 2
          (Just "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, height REAL)")
      , schemaRow 2 "index" "people_age" "people" 3 (Just "CREATE INDEX people_age ON people(age)")
      , schemaRow 3 "table" "blobs" "blobs" 4 (Just "CREATE TABLE blobs(id INTEGER PRIMARY KEY, data BLOB)")
      , schemaRow 4 "table" "deep" "deep" 7 (Just "CREATE TABLE deep(n INTEGER PRIMARY KEY, v TEXT)")
      ]
    header =
      BS.concat
        [ B.pack "SQLite format 3\0"
        , BS.pack (be 2 pageSize)
        , BS.pack [1, 1, 0, 64, 32, 32]
        , BS.pack (be 4 1)
        , BS.pack (be 4 9) -- 28: database size in pages
        , BS.replicate (56 - 32) 0
        , BS.pack (be 4 1) -- 56: UTF-8
        , BS.replicate (100 - 60) 0
        ]
    page1 = pad (header <> BS.drop 100 (btreePage True 0x0d Nothing schemaCells))
    person rowid name age height =
      leafTableCell rowid (encodeRecord [VNull, name, age, height])
    p2 =
      pad $
        btreePage False 0x0d Nothing
          [ person 1 (t "Ada") (VInt 36) (VReal 1.65)
          , person 2 (t "Grace") (VInt 45) (VInt 2) -- REAL column stored as integer
          , person 3 (t "Alan") VNull (VReal 1.8)
          , person 6 (t "") (VInt 45) (VReal 0)
          ]
    indexCell age rowid = let rec = encodeRecord [age, VInt rowid] in encodeVarint (fromIntegral (BS.length rec)) <> rec
    p3 =
      pad $
        btreePage False 0x0a Nothing
          [indexCell VNull 3, indexCell (VInt 36) 1, indexCell (VInt 45) 2, indexCell (VInt 45) 6]
    -- blobs: row 1 has a 1000-byte blob; overflow pages 5 and 6
    fullRec = encodeRecord [VNull, VBlob blobPayload]
    localLen = 39 -- M for a 512-byte page
    cell4 =
      encodeVarint (fromIntegral (BS.length fullRec))
        <> encodeVarint 1
        <> BS.take localLen fullRec
        <> BS.pack (be 4 5)
    p4 = pad (btreePage False 0x0d Nothing [cell4])
    rest = BS.drop localLen fullRec
    p5 = pad (BS.pack (be 4 6) <> BS.take (pageSize - 4) rest)
    p6 = pad (BS.pack (be 4 0) <> BS.drop (pageSize - 4) rest)
    deepRow n = leafTableCell n (encodeRecord [VNull, t ("row" ++ show n)])
    p7 = pad (btreePage False 0x05 (Just 9) [BS.pack (be 4 8) <> encodeVarint 3])
    p8 = pad (btreePage False 0x0d Nothing (map deepRow [1, 2, 3]))
    p9 = pad (btreePage False 0x0d Nothing (map deepRow [4, 5, 6]))

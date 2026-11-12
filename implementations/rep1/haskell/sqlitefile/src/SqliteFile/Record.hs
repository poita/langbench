-- | Decoding SQLite records (table rows and index entries).
module SqliteFile.Record
  ( decodeRecord
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import GHC.Float (castWord64ToDouble)
import SqliteFile.Error (corrupt)
import SqliteFile.Value (Value (..))
import SqliteFile.Varint (getBESigned, getVarint)

-- | Decode a record into its column values. The list is produced lazily, so
-- a caller that only needs the first few columns does not decode the rest.
decodeRecord :: ByteString -> [Value]
decodeRecord rec = go hdrStart bodyStart
  where
    (hdrSizeI, hdrVarintLen) = getVarint rec 0
    hdrSize = fromIntegral hdrSizeI :: Int
    hdrStart = hdrVarintLen
    bodyStart = hdrSize
    go hp bp
      | hp >= hdrSize = []
      | otherwise =
          let (st, n) = getVarint rec hp
              size = serialSize st
           in decodeValue rec st bp : go (hp + n) (bp + size)

-- Bytes occupied by a value of the given serial type.
serialSize :: Int64 -> Int
serialSize st = case st of
  0 -> 0
  1 -> 1
  2 -> 2
  3 -> 3
  4 -> 4
  5 -> 6
  6 -> 8
  7 -> 8
  8 -> 0
  9 -> 0
  _ | st >= 12 -> fromIntegral ((st - 12) `div` 2)
    | otherwise -> corrupt ("invalid serial type " ++ show st)

decodeValue :: ByteString -> Int64 -> Int -> Value
decodeValue rec st off = case st of
  0 -> VNull
  1 -> VInt (getBESigned rec off 1)
  2 -> VInt (getBESigned rec off 2)
  3 -> VInt (getBESigned rec off 3)
  4 -> VInt (getBESigned rec off 4)
  5 -> VInt (getBESigned rec off 6)
  6 -> VInt (getBESigned rec off 8)
  7 -> VReal (castWord64ToDouble (fromIntegral (getBESigned rec off 8)))
  8 -> VInt 0
  9 -> VInt 1
  _ | even st -> VBlob (slice (fromIntegral ((st - 12) `div` 2)))
    | otherwise -> VText (slice (fromIntegral ((st - 13) `div` 2)))
  where
    slice len
      | off + len > BS.length rec = corrupt "record body is truncated"
      | otherwise = BS.take len (BS.drop off rec)


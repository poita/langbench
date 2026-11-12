-- | SQLite varints and big-endian integer helpers.
module SqliteFile.Varint
  ( getVarint
  , getBE
  , getBESigned
  ) where

import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Word (Word64)
import SqliteFile.Error (corrupt)

-- | Decode the varint at the given offset, returning the signed 64-bit value
-- and the number of bytes used (1 to 9).
getVarint :: ByteString -> Int -> (Int64, Int)
getVarint bs off = go 0 0
  where
    byte i = case BS.indexMaybe bs (off + i) of
      Just b -> b
      Nothing -> corrupt "varint runs past the end of the data"
    go :: Word64 -> Int -> (Int64, Int)
    go acc i
      | i == 8 = (fromIntegral ((acc `shiftL` 8) .|. fromIntegral (byte 8)), 9)
      | otherwise =
          let b = byte i
              acc' = (acc `shiftL` 7) .|. fromIntegral (b `mod` 128)
           in if b >= 128 then go acc' (i + 1) else (fromIntegral acc', i + 1)

-- | Unsigned big-endian integer of @n@ bytes at the offset.
getBE :: ByteString -> Int -> Int -> Int
getBE bs off n
  | off < 0 || off + n > BS.length bs = corrupt "read past the end of the data"
  | otherwise = BS.foldl' (\a b -> a * 256 + fromIntegral b) 0 (BS.take n (BS.drop off bs))

-- | Signed (two's-complement) big-endian integer of @n@ bytes (n <= 8).
getBESigned :: ByteString -> Int -> Int -> Int64
getBESigned bs off n
  | off < 0 || off + n > BS.length bs = corrupt "read past the end of the data"
  | n == 0 = 0
  | otherwise =
      let w = BS.foldl' (\a b -> (a `shiftL` 8) .|. fromIntegral b) (0 :: Word64) (BS.take n (BS.drop off bs))
          -- Shift the value to the top of the word, then arithmetic-shift back.
       in fromIntegral (w `shiftL` (64 - 8 * n) ) `shiftR` (64 - 8 * n)

-- | CRC-32 (reflected polynomial @0xEDB88320@), table driven (SPEC §3).
module Tessera.CRC
  ( crc32
  , crc32Chunks
  ) where

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits (complement, shiftR, xor, (.&.))
import qualified Data.ByteString as BS
import Data.Word (Word32)

table :: UArray Int Word32
table = listArray (0, 255) [entry (fromIntegral n) | n <- [0 .. 255 :: Int]]
  where
    entry :: Word32 -> Word32
    entry c0 = iterate step c0 !! 8
    step c
      | c .&. 1 /= 0 = (c `shiftR` 1) `xor` 0xEDB88320
      | otherwise = c `shiftR` 1

update :: Word32 -> BS.ByteString -> Word32
update = BS.foldl' step
  where
    step c b = (table `unsafeAt` fromIntegral ((c `xor` fromIntegral b) .&. 0xFF)) `xor` (c `shiftR` 8)

-- | CRC-32 of a byte string.
--
-- >>> crc32 (BS.pack [0x61])
-- 3904355907
crc32 :: BS.ByteString -> Word32
crc32 bs = crc32Chunks [bs]

-- | CRC-32 of the concatenation of several chunks, without concatenating them.
crc32Chunks :: [BS.ByteString] -> Word32
crc32Chunks = complement . foldl' update 0xFFFFFFFF

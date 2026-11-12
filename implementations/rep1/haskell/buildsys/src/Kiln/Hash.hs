-- | 64-bit FNV-1a content hashing, as used by every Kiln hash.
module Kiln.Hash
  ( Hash
  , fnv1a64
  , hashHex
  , parseHashHex
  ) where

import Data.Bits (shiftR, (.&.), xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64)

-- | A content hash.
type Hash = Word64

-- | The FNV-1a 64-bit hash of a byte string.
--
-- >>> hashHex (fnv1a64 "")
-- "cbf29ce484222325"
fnv1a64 :: BS.ByteString -> Hash
fnv1a64 = BS.foldl' step 0xcbf29ce484222325
  where
    step h b = (h `xor` fromIntegral b) * 0x100000001b3

-- | Render a hash as exactly 16 lowercase hexadecimal digits.
hashHex :: Hash -> BS.ByteString
hashHex h = BC.pack [digit ((h `shiftR` (4 * i)) .&. 15) | i <- [15, 14 .. 0]]
  where
    digit d = "0123456789abcdef" !! fromIntegral d

-- | Parse exactly 16 lowercase hexadecimal digits.
parseHashHex :: BS.ByteString -> Maybe Hash
parseHashHex s
  | BS.length s == 16 && BC.all isLowerHex s = Just (BS.foldl' (\a c -> a * 16 + val c) 0 s)
  | otherwise = Nothing
  where
    isLowerHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    val c
      | c >= 0x30 && c <= 0x39 = fromIntegral c - 0x30
      | otherwise = fromIntegral c - 0x61 + 10

-- | Big-endian integer helpers shared by the page, log and value codecs.
module Tessera.Binary
  ( be16
  , be32
  , be64
  , w16
  , w32
  , zeros
  ) where

import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder, byteString, word16BE, word32BE)
import Data.Word (Word64)

-- | Unsigned big-endian 16-bit integer at a byte offset.
be16 :: BS.ByteString -> Int -> Int
be16 bs o = (fromIntegral (BS.index bs o) `shiftL` 8) .|. fromIntegral (BS.index bs (o + 1))

-- | Unsigned big-endian 32-bit integer at a byte offset.
be32 :: BS.ByteString -> Int -> Int
be32 bs o = (be16 bs o `shiftL` 16) .|. be16 bs (o + 2)

-- | Unsigned big-endian 64-bit integer at a byte offset.
be64 :: BS.ByteString -> Int -> Word64
be64 bs o = (fromIntegral (be32 bs o) `shiftL` 32) .|. fromIntegral (be32 bs (o + 4))

-- | 16-bit big-endian builder from an 'Int'.
w16 :: Int -> Builder
w16 = word16BE . fromIntegral

-- | 32-bit big-endian builder from an 'Int'.
w32 :: Int -> Builder
w32 = word32BE . fromIntegral

-- | @n@ zero bytes.
zeros :: Int -> Builder
zeros n = byteString (BS.replicate n 0)

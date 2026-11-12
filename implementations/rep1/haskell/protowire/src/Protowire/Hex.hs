-- |
-- Module      : Protowire.Hex
-- Description : Lowercase hexadecimal encoding and strict decoding.
module Protowire.Hex
  ( decodeHex
  , encodeHex
  , encodeHexLazy
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder, byteStringHex)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

nibble :: Word8 -> Maybe Word8
nibble w
  | w >= 0x30 && w <= 0x39 = Just (w - 0x30)
  | w >= 0x61 && w <= 0x66 = Just (w - 0x61 + 10)
  | otherwise = Nothing

isNibble :: Word8 -> Bool
isNibble w = (w >= 0x30 && w <= 0x39) || (w >= 0x61 && w <= 0x66)

-- | Decode lowercase hex (no separators).  'Nothing' on an odd length or on
-- any character outside @[0-9a-f]@ (uppercase included).  The empty string
-- decodes to the empty byte string.
decodeHex :: ByteString -> Maybe ByteString
decodeHex s
  | odd len || not (BS.all isNibble s) = Nothing
  | otherwise = Just (fst (BS.unfoldrN (len `div` 2) step 0))
  where
    len = BS.length s
    val i = maybe 0 id (nibble (BU.unsafeIndex s i))
    step i = Just ((val i `shiftL` 4) .|. val (i + 1), i + 2)

-- | Lowercase hex of a byte string.
encodeHex :: ByteString -> Builder
encodeHex = byteStringHex

-- | Lowercase hex of a lazy byte string, chunk by chunk.
encodeHexLazy :: BL.ByteString -> Builder
encodeHexLazy = BL.foldrChunks (\c b -> byteStringHex c <> b) mempty

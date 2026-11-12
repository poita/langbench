-- |
-- Module      : Codec.Compression.Inflate.Hex
-- Description : Lowercase hexadecimal encoding and decoding of byte strings.
module Codec.Compression.Inflate.Hex
  ( encodeHex
  , decodeHex
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)
import Foreign.Storable (pokeByteOff)

-- | Encode bytes as lowercase hexadecimal, two digits per byte.
--
-- >>> encodeHex (B.pack [0x41, 0xff])
-- "41ff"
encodeHex :: B.ByteString -> B.ByteString
encodeHex bs = BI.unsafeCreate (2 * n) $ \p ->
  let go !i
        | i >= n = return ()
        | otherwise = do
            let b = BU.unsafeIndex bs i
            pokeByteOff p (2 * i) (digit (b `shiftR` 4))
            pokeByteOff p (2 * i + 1) (digit (b .&. 15))
            go (i + 1)
  in go 0
  where
    n = B.length bs
    digit :: Word8 -> Word8
    digit d = if d < 10 then 48 + d else 87 + d

-- | Decode hexadecimal text (upper or lower case) into bytes. Returns
-- 'Nothing' if the length is odd or a character is not a hex digit.
decodeHex :: B.ByteString -> Maybe B.ByteString
decodeHex txt
  | odd len = Nothing
  | B.any ((> 15) . val) txt = Nothing
  | otherwise = Just $ BI.unsafeCreate half $ \p ->
      let go !i
            | i >= half = return ()
            | otherwise = do
                let hi = val (BU.unsafeIndex txt (2 * i))
                    lo = val (BU.unsafeIndex txt (2 * i + 1))
                pokeByteOff p i ((hi `shiftL` 4) .|. lo)
                go (i + 1)
      in go 0
  where
    len = B.length txt
    half = len `div` 2
    -- Value of a hex digit; anything else maps to 255.
    val :: Word8 -> Word8
    val c
      | c >= 48 && c <= 57  = c - 48
      | c >= 97 && c <= 102 = c - 87
      | c >= 65 && c <= 70  = c - 55
      | otherwise           = 255

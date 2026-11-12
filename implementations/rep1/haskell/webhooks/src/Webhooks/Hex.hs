-- | Lowercase hexadecimal encoding and the @\<hex\>@ field syntax used by the
-- command-line protocol.
module Webhooks.Hex
  ( encodeHex
  , decodeHex
  , parseHexField
  , renderHexField
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

-- | Encode bytes as lowercase hexadecimal digits.
--
-- >>> encodeHex (BS.pack [0xde, 0xad])
-- "dead"
encodeHex :: ByteString -> ByteString
encodeHex bs = fst (BS.unfoldrN (2 * BS.length bs) step 0)
  where
    step :: Int -> Maybe (Word8, Int)
    step i =
      let b = BU.unsafeIndex bs (i `shiftR` 1)
          nib = if even i then b `shiftR` 4 else b .&. 15
       in Just (digit nib, i + 1)
    digit n = if n < 10 then 48 + n else 87 + n

-- | Decode an even-length run of lowercase hex digits. Uppercase digits, odd
-- lengths and any other character yield 'Nothing'.
decodeHex :: ByteString -> Maybe ByteString
decodeHex s
  | odd n || not (BS.all isLowerHex s) = Nothing
  | otherwise = Just (fst (BS.unfoldrN (n `div` 2) step 0))
  where
    n = BS.length s
    step i =
      Just ((val (BU.unsafeIndex s i) `shiftL` 4) .|. val (BU.unsafeIndex s (i + 1)), i + 2)
    val c = if c <= 57 then c - 48 else c - 87

isLowerHex :: Word8 -> Bool
isLowerHex c = (c >= 48 && c <= 57) || (c >= 97 && c <= 102)

-- | Parse a @\<hex\>@ protocol field: lowercase hex digits, or the single
-- character @-@ for the empty byte string. A zero-length field is never valid.
parseHexField :: ByteString -> Maybe ByteString
parseHexField s
  | s == BS.singleton 45 = Just BS.empty
  | BS.null s = Nothing
  | otherwise = decodeHex s

-- | Render bytes as a @\<hex\>@ field: lowercase hex, or @-@ when empty.
renderHexField :: ByteString -> ByteString
renderHexField bs
  | BS.null bs = BS.singleton 45
  | otherwise = encodeHex bs

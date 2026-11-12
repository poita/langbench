-- | Content-Transfer-Encoding decoders, written by hand.
module Mime.Transfer
  ( decodeBody
  , decodeQuotedPrintable
  , decodeBase64
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Word (Word8)

-- | @decodeBody encoding bytes@: the encoding token must already be
-- normalised (stripped, lower-case).  Unknown encodings leave the bytes alone.
decodeBody :: String -> B.ByteString -> B.ByteString
decodeBody "quoted-printable" = decodeQuotedPrintable
decodeBody "base64" = decodeBase64
decodeBody _ = id

hexDigit :: Word8 -> Maybe Word8
hexDigit w
  | w >= 48 && w <= 57 = Just (w - 48)
  | w >= 97 && w <= 102 = Just (w - 87)
  | w >= 65 && w <= 70 = Just (w - 55)
  | otherwise = Nothing

-- | Quoted-printable decoding (input has LF line endings).
decodeQuotedPrintable :: B.ByteString -> B.ByteString
decodeQuotedPrintable = BL.toStrict . BB.toLazyByteString . go
  where
    go bs = case B.elemIndex 61 bs of
      Nothing -> BB.byteString bs
      Just i ->
        let (pre, rest) = B.splitAt i bs
            after = B.drop 1 rest
         in BB.byteString pre <> eq after
    eq after = case B.uncons after of
      Nothing -> mempty
      Just (10, r) -> go r
      Just (a, r1) -> case B.uncons r1 of
        Just (b, r2) | Just x <- hexDigit a, Just y <- hexDigit b ->
          BB.word8 (x `shiftL` 4 .|. y) <> go r2
        _ -> BB.word8 61 <> go after

-- | Base64 decoding: non-alphabet bytes (including @=@) are discarded and a
-- dangling final character is dropped.
decodeBase64 :: B.ByteString -> B.ByteString
decodeBase64 bs = BL.toStrict (BB.toLazyByteString (go vals))
  where
    vals = [v | w <- B.unpack bs, Just v <- [sextet w]]
    go (a : b : c : d : r) =
      BB.word8 (a `shiftL` 2 .|. b `shiftR` 4)
        <> BB.word8 ((b .&. 15) `shiftL` 4 .|. c `shiftR` 2)
        <> BB.word8 ((c .&. 3) `shiftL` 6 .|. d)
        <> go r
    go [a, b] = BB.word8 (a `shiftL` 2 .|. b `shiftR` 4)
    go [a, b, c] =
      BB.word8 (a `shiftL` 2 .|. b `shiftR` 4)
        <> BB.word8 ((b .&. 15) `shiftL` 4 .|. c `shiftR` 2)
    go _ = mempty

sextet :: Word8 -> Maybe Word8
sextet w
  | w >= 65 && w <= 90 = Just (w - 65)
  | w >= 97 && w <= 122 = Just (w - 71)
  | w >= 48 && w <= 57 = Just (w + 4)
  | w == 43 = Just 62
  | w == 47 = Just 63
  | otherwise = Nothing

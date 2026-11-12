{-# LANGUAGE BangPatterns #-}

-- | Base64 encoding (standard padded and URL-safe unpadded alphabets) and a
-- strict, alphabet-agnostic decoder.
module Webhooks.Base64
  ( encodeStandard
  , encodeUrlSafe
  , decode
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

standardAlphabet, urlSafeAlphabet :: ByteString
standardAlphabet = BC.pack "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
urlSafeAlphabet = BC.pack "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- | Standard Base64 with @=@ padding to a multiple of four characters.
--
-- >>> encodeStandard (BS.pack [0xfb, 0xff])
-- "+/8="
encodeStandard :: ByteString -> ByteString
encodeStandard = encodeWith standardAlphabet True

-- | URL-safe Base64 (@-@ and @_@) without padding.
--
-- >>> encodeUrlSafe (BS.pack [0xfb, 0xff])
-- "-_8"
encodeUrlSafe :: ByteString -> ByteString
encodeUrlSafe = encodeWith urlSafeAlphabet False

encodeWith :: ByteString -> Bool -> ByteString -> ByteString
encodeWith alphabet pad bs = BS.pack (go 0)
  where
    n = BS.length bs
    ch :: Int -> Word8
    ch i = BU.unsafeIndex alphabet (i .&. 63)
    at i = fromIntegral (BU.unsafeIndex bs i) :: Int
    go !i
      | i + 3 <= n =
          let v = (at i `shiftL` 16) .|. (at (i + 1) `shiftL` 8) .|. at (i + 2)
           in ch (v `shiftR` 18) : ch (v `shiftR` 12) : ch (v `shiftR` 6) : ch v : go (i + 3)
      | n - i == 2 =
          let v = (at i `shiftL` 8) .|. at (i + 1)
           in [ch (v `shiftR` 10), ch (v `shiftR` 4), ch (v `shiftL` 2)] ++ [61 | pad]
      | n - i == 1 =
          let v = at i
           in [ch (v `shiftR` 2), ch (v `shiftL` 4)] ++ (if pad then [61, 61] else [])
      | otherwise = []

-- | Decode Base64 text.
--
-- * a trailing run of @=@ is padding, and must be exactly the padding the
--   encoder would have produced; an @=@ anywhere else is invalid;
-- * the body may use the standard or the URL-safe alphabet, but not both;
-- * a body length of @1 (mod 4)@ is invalid;
-- * left-over low bits of the final character are discarded unchecked, so
--   @QQ==@ and @QR==@ both decode to @0x41@.
--
-- The empty string is valid and decodes to the empty byte string.
decode :: ByteString -> Maybe ByteString
decode input
  | not (BS.all validChar body) = Nothing
  | BS.any (`elem` [43, 47]) body && BS.any (`elem` [45, 95]) body = Nothing
  | r == 1 = Nothing
  | p > 0 && not paddingOk = Nothing
  | otherwise = Just (BS.pack (go 0))
  where
    (body, padding) = BS.spanEnd (== 61) input
    p = BS.length padding
    n = BS.length body
    r = n `mod` 4
    paddingOk = (r == 3 && p == 1) || (r == 2 && p == 2)
    v :: Int -> Int
    v i = sextet (BU.unsafeIndex body i)
    byte :: Int -> Word8
    byte = fromIntegral
    go !i
      | i + 4 <= n =
          let x = (v i `shiftL` 18) .|. (v (i + 1) `shiftL` 12) .|. (v (i + 2) `shiftL` 6) .|. v (i + 3)
           in byte (x `shiftR` 16) : byte (x `shiftR` 8) : byte x : go (i + 4)
      | n - i == 3 =
          let x = (v i `shiftL` 10) .|. (v (i + 1) `shiftL` 4) .|. (v (i + 2) `shiftR` 2)
           in [byte (x `shiftR` 8), byte x]
      | n - i == 2 = [byte ((v i `shiftL` 2) .|. (v (i + 1) `shiftR` 4))]
      | otherwise = []

-- | Whether a byte is in the standard or the URL-safe alphabet.
validChar :: Word8 -> Bool
validChar c =
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
    || c == 43 || c == 47 || c == 45 || c == 95

-- | The 6-bit value of a character already known to satisfy 'validChar'.
sextet :: Word8 -> Int
sextet c
  | c >= 65 && c <= 90 = fromIntegral c - 65
  | c >= 97 && c <= 122 = fromIntegral c - 71
  | c >= 48 && c <= 57 = fromIntegral c + 4
  | c == 43 || c == 45 = 62
  | otherwise = 63

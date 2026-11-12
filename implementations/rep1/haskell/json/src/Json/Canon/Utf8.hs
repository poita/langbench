{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Json.Canon.Utf8
-- Description : Strict UTF-8 (RFC 3629) validation in one forward pass.
module Json.Canon.Utf8
  ( validateUtf8
  ) where

import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

-- | Check that a byte string is well-formed UTF-8: no overlong forms, no
-- encoded surrogates, nothing above U+10FFFF, no truncated sequence.
--
-- Returns 'Nothing' if valid, otherwise the offset of the first offending
-- sequence.
validateUtf8 :: ByteString -> Maybe Int
validateUtf8 bs = go 0
  where
    !n = BS.length bs
    at :: Int -> Word8
    at = BU.unsafeIndex bs
    -- Is byte i present and a continuation byte (10xxxxxx)?
    cont i = i < n && at i .&. 0xC0 == 0x80
    -- Is byte i present and within [lo, hi]?
    inR lo hi i = i < n && at i >= lo && at i <= hi
    go !i
      | i >= n = Nothing
      | b < 0x80 = go (i + 1)
      | b >= 0xC2 && b <= 0xDF = if cont (i + 1) then go (i + 2) else Just i
      | b == 0xE0 = if inR 0xA0 0xBF (i + 1) && cont (i + 2) then go (i + 3) else Just i
      | b == 0xED = if inR 0x80 0x9F (i + 1) && cont (i + 2) then go (i + 3) else Just i
      | b >= 0xE1 && b <= 0xEF = if cont (i + 1) && cont (i + 2) then go (i + 3) else Just i
      | b == 0xF0 = if inR 0x90 0xBF (i + 1) && cont (i + 2) && cont (i + 3) then go (i + 4) else Just i
      | b == 0xF4 = if inR 0x80 0x8F (i + 1) && cont (i + 2) && cont (i + 3) then go (i + 4) else Just i
      | b >= 0xF1 && b <= 0xF3 = if cont (i + 1) && cont (i + 2) && cont (i + 3) then go (i + 4) else Just i
      | otherwise = Just i
      where
        b = at i

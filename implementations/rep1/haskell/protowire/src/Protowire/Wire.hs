{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Protowire.Wire
-- Description : Low-level wire-format primitives: varints, tags, skipping.
--
-- All readers take the byte string of the /enclosing message/ and an offset
-- into it, and return the value together with the offset just past it.
-- Nothing is ever read beyond the end of the byte string.
module Protowire.Wire
  ( WireError (..)
  , readVarint
  , readTag
  , readLength
  , skipField
    -- * Writing
  , varint
  , varintSize
  , zigzag32
  , zigzag64
  , unzigzag32
  , unzigzag64
  ) where

import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder, word8)
import qualified Data.ByteString.Unsafe as BU
import Data.Int (Int32, Int64)
import Data.Word (Word32, Word64)

-- | Why a byte string is not a valid message.
data WireError
  = -- | Input ended in the middle of a value.
    Truncated
  | -- | A varint longer than its limit (10 bytes; 5 for tags and lengths).
    VarintTooLong
  | -- | A tag with field number 0 or a value of 2^32 or more.
    InvalidTag
  | -- | Wire type 6 or 7.
    InvalidWireType
  | -- | A length prefix larger than the bytes remaining.
    LengthOutOfRange
  | -- | An end-group tag with no matching start, or with the wrong number.
    UnmatchedEndGroup
  | -- | A string field that is not valid UTF-8.
    InvalidUtf8
  | -- | A packed payload whose length is not a whole number of elements.
    MalformedPacked
  deriving (Eq, Show)

-- | @readVarint maxBytes bs i@ reads a base-128 varint of at most
-- @maxBytes@ bytes starting at offset @i@.  Bits beyond the 64th are
-- discarded; non-minimal encodings are accepted.
readVarint :: Int -> ByteString -> Int -> Either WireError (Word64, Int)
readVarint maxBytes bs = go 0 0
  where
    n = BS.length bs
    go :: Int -> Word64 -> Int -> Either WireError (Word64, Int)
    go !k !acc !i
      | i >= n = Left Truncated
      | otherwise =
          let b = BU.unsafeIndex bs i
              acc' = acc .|. (fromIntegral (b .&. 0x7f) `shiftL` (7 * k))
           in if b < 0x80
                then Right (acc', i + 1)
                else
                  if k + 1 >= maxBytes
                    then Left VarintTooLong
                    else go (k + 1) acc' (i + 1)

-- | Read a tag: a varint of at most 5 bytes and value below 2^32, giving
-- the field number (at least 1) and wire type (0, 1, 2, 3, 4 or 5).
readTag :: ByteString -> Int -> Either WireError (Int, Int, Int)
readTag bs i = do
  (t, i') <- readVarint 5 bs i
  if t >= 0x100000000
    then Left InvalidTag
    else do
      let num = fromIntegral (t `shiftR` 3)
          wt = fromIntegral (t .&. 7)
      if num < 1
        then Left InvalidTag
        else if wt > 5 then Left InvalidWireType else Right (num, wt, i')

-- | Read a length prefix: at most 5 bytes, and not more than the bytes
-- remaining after it.
readLength :: ByteString -> Int -> Either WireError (Int, Int)
readLength bs i = do
  (l, i') <- readVarint 5 bs i
  if l > fromIntegral (BS.length bs - i')
    then Left LengthOutOfRange
    else Right (fromIntegral l, i')

-- | @skipField num wt bs i@ skips the payload of a field whose tag (field
-- number @num@, wire type @wt@) has just been read, returning the offset
-- after it.  Groups are skipped through their matching end tag.  Wire type 4
-- must not be passed in (it is an error at the caller's level).
skipField :: Int -> Int -> ByteString -> Int -> Either WireError Int
skipField num wt bs i = case wt of
  0 -> snd <$> readVarint 10 bs i
  1 -> fixed 8
  5 -> fixed 4
  2 -> do
    (l, i') <- readLength bs i
    Right (i' + l)
  3 -> skipGroup num bs i
  4 -> Left UnmatchedEndGroup
  _ -> Left InvalidWireType
  where
    fixed k
      | i + k <= BS.length bs = Right (i + k)
      | otherwise = Left Truncated

skipGroup :: Int -> ByteString -> Int -> Either WireError Int
skipGroup groupNum bs = go
  where
    go i = do
      (num, wt, i') <- readTag bs i
      if wt == 4
        then if num == groupNum then Right i' else Left UnmatchedEndGroup
        else skipField num wt bs i' >>= go

------------------------------------------------------------------------------
-- Writing

-- | A minimal varint.
varint :: Word64 -> Builder
varint !w
  | w < 0x80 = word8 (fromIntegral w)
  | otherwise = word8 (fromIntegral (w .&. 0x7f) .|. 0x80) <> varint (w `shiftR` 7)

-- | The length in bytes of the minimal varint for a value.
varintSize :: Word64 -> Int
varintSize = go 1
  where
    go !k !w = if w < 0x80 then k else go (k + 1) (w `shiftR` 7)

-- | @(v << 1) ^ (v >> 31)@ as an unsigned 32-bit value.
zigzag32 :: Int32 -> Word32
zigzag32 v = fromIntegral ((v `shiftL` 1) `xor` (v `shiftR` 31))

-- | @(v << 1) ^ (v >> 63)@ as an unsigned 64-bit value.
zigzag64 :: Int64 -> Word64
zigzag64 v = fromIntegral ((v `shiftL` 1) `xor` (v `shiftR` 63))

unzigzag32 :: Word32 -> Int32
unzigzag32 u = fromIntegral (u `shiftR` 1) `xor` negate (fromIntegral (u .&. 1))

unzigzag64 :: Word64 -> Int64
unzigzag64 u = fromIntegral (u `shiftR` 1) `xor` negate (fromIntegral (u .&. 1))


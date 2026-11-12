-- |
-- Module      : Codec.Compression.Inflate
-- Description : Decompress raw DEFLATE (RFC 1951) streams.
--
-- A self-contained DEFLATE decoder: no zlib, gzip or other decompression
-- library is involved. Huffman codes are decoded with two-level lookup tables
-- ("Codec.Compression.Inflate.Huffman").
--
-- > import qualified Data.ByteString as B
-- > import Codec.Compression.Inflate
-- >
-- > -- one stored block holding the byte 0x41
-- > inflate (B.pack [0x01, 0x01, 0x00, 0xfe, 0xff, 0x41]) == Right (B.pack [0x41])
--
-- The decoder is strict about malformed input: besides the structural errors
-- of RFC 1951 it rejects incomplete or over-subscribed Huffman codes (apart
-- from the single-code and empty-distance-code cases zlib accepts), and any
-- whole bytes left over after the final block.
module Codec.Compression.Inflate
  ( inflate
  , InflateError (..)
  , describeError
  ) where

import Control.Exception (try)
import qualified Data.ByteString as B
import System.IO.Unsafe (unsafePerformIO)

import Codec.Compression.Inflate.Decoder (decode)
import Codec.Compression.Inflate.Types

-- | Decompress a raw DEFLATE stream (no zlib or gzip wrapper).
--
-- Returns the decompressed bytes, or the first 'InflateError' found. The
-- whole input must be a single complete stream: the stream ending early and
-- extra bytes after the final block are both errors.
--
-- Runs in O(input + output) time plus O(symbols + 2^root) per block for
-- building the Huffman tables.
inflate :: B.ByteString -> Either InflateError B.ByteString
inflate input = unsafePerformIO (try (decode input))
{-# NOINLINE inflate #-}

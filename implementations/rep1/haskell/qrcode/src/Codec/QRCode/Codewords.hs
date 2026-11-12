-- | From a segment's bit fields to the final interleaved codeword sequence:
-- bit packing, terminator, padding, Reed-Solomon blocks and interleaving.
module Codec.QRCode.Codewords
  ( packBits
  , padDataCodewords
  , splitBlocks
  , buildCodewords
  ) where

import Data.Bits (bit, shiftL, shiftR, (.&.), (.|.))
import Data.List (mapAccumL, transpose)
import Data.Word (Word8)

import Codec.QRCode.ReedSolomon (generatorPoly, remainder)
import Codec.QRCode.Segment (Field)
import Codec.QRCode.Tables
import Codec.QRCode.Types (Ecl)

-- | Pack @(value, width)@ fields MSB-first into bytes; a final partial byte
-- is padded with zero bits.
packBits :: [Field] -> [Word8]
packBits = go 0 0
  where
    go :: Int -> Int -> [Field] -> [Word8]
    go !acc !n [] = [fromIntegral (acc `shiftL` (8 - n)) | n > 0]
    go !acc !n ((v, w) : fs) = emit ((acc `shiftL` w) .|. v) (n + w) fs

    emit :: Int -> Int -> [Field] -> [Word8]
    emit !acc !n fs
      | n >= 8 =
          fromIntegral (acc `shiftR` (n - 8))
            : emit (acc .&. (bit (n - 8) - 1)) (n - 8) fs
      | otherwise = go acc n fs

-- | Turn a segment's fields into exactly @dataCodewords ecl v@ bytes:
-- terminator, zero padding to a byte boundary, then alternating @0xEC@ and
-- @0x11@ pad codewords. The fields must fit in the capacity.
padDataCodewords :: Ecl -> Int -> [Field] -> [Word8]
padDataCodewords ecl v fields = take cap (packBits (fields ++ [(0, term)]) ++ cycle [0xEC, 0x11])
  where
    cap = dataCodewords ecl v
    len = sum (map snd fields)
    term = min 4 (8 * cap - len)

-- | Split data codewords into the version's blocks (short blocks first).
splitBlocks :: Ecl -> Int -> [Word8] -> [[Word8]]
splitBlocks ecl v dat = snd (mapAccumL cut dat lens)
  where
    t = totalCodewords v
    b = numBlocks ecl v
    shortLen = t `div` b - eccCodewordsPerBlock ecl v
    nShort = b - t `mod` b
    lens = replicate nShort shortLen ++ replicate (b - nShort) (shortLen + 1)
    cut xs n = let (h, rest) = splitAt n xs in (rest, h)

-- | Compute error correction for every block of the padded data codewords and
-- return the final sequence: interleaved data followed by interleaved ECC.
buildCodewords :: Ecl -> Int -> [Word8] -> [Word8]
buildCodewords ecl v dat = concat (transpose blocks) ++ concat (transpose eccs)
  where
    blocks = splitBlocks ecl v dat
    e = eccCodewordsPerBlock ecl v
    gen = generatorPoly e
    eccs = map (remainder e gen) blocks

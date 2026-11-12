-- |
-- Module      : Codec.Compression.Inflate.Tables
-- Description : Constant tables from RFC 1951.
module Codec.Compression.Inflate.Tables
  ( lengthBase
  , lengthExtra
  , distBase
  , distExtra
  , codeLengthOrder
  , fixedLitLenLengths
  , fixedDistLengths
  ) where

import Data.Array.Unboxed (UArray, listArray)
import Data.Word (Word8)

-- | Base match length for literal/length symbols 257..285 (indexed by
-- @symbol - 257@).
lengthBase :: UArray Int Int
lengthBase = listArray (0, 28)
  [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59
  , 67, 83, 99, 115, 131, 163, 195, 227, 258]

-- | Number of extra bits for literal/length symbols 257..285.
lengthExtra :: UArray Int Int
lengthExtra = listArray (0, 28)
  [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3
  , 4, 4, 4, 4, 5, 5, 5, 5, 0]

-- | Base distance for distance symbols 0..29.
distBase :: UArray Int Int
distBase = listArray (0, 29)
  [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513
  , 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

-- | Number of extra bits for distance symbols 0..29.
distExtra :: UArray Int Int
distExtra = listArray (0, 29)
  [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8
  , 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

-- | The order in which code-length-code lengths appear in a dynamic header.
codeLengthOrder :: UArray Int Int
codeLengthOrder = listArray (0, 18)
  [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

-- | Code lengths of the fixed literal/length code (288 symbols).
fixedLitLenLengths :: UArray Int Word8
fixedLitLenLengths = listArray (0, 287) $
  replicate 144 8 ++ replicate 112 9 ++ replicate 24 7 ++ replicate 8 8

-- | Code lengths of the fixed distance code (32 symbols).
fixedDistLengths :: UArray Int Word8
fixedDistLengths = listArray (0, 31) (replicate 32 5)

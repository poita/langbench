-- | 64-bit FNV-1a content hashing, as used throughout Kiln.
module Kiln.Hash
  ( Hash
  , fnv1a
  , renderHash
  , parseHash
  ) where

import Data.Bits (shiftR, xor, (.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64)

-- | A content hash.
type Hash = Word64

-- | The 64-bit FNV-1a hash of a byte string. The empty string hashes to
-- @0xcbf29ce484222325@.
fnv1a :: B.ByteString -> Hash
fnv1a = B.foldl' step 0xcbf29ce484222325
  where
    step h b = (h `xor` fromIntegral b) * 0x100000001b3
{-# INLINE fnv1a #-}

-- | Render a hash as exactly 16 lowercase hexadecimal digits.
renderHash :: Hash -> B.ByteString
renderHash h = BC.pack [digit ((h `shiftR` (4 * i)) .&. 15) | i <- [15, 14 .. 0]]
  where
    digit d = "0123456789abcdef" !! fromIntegral d

-- | Parse exactly 16 lowercase hexadecimal digits.
parseHash :: B.ByteString -> Maybe Hash
parseHash s
  | B.length s /= 16 = Nothing
  | otherwise = B.foldl' go (Just 0) s
  where
    go Nothing _ = Nothing
    go (Just acc) c
      | c >= 48 && c <= 57 = Just (acc * 16 + fromIntegral (c - 48))
      | c >= 97 && c <= 102 = Just (acc * 16 + fromIntegral (c - 87))
      | otherwise = Nothing

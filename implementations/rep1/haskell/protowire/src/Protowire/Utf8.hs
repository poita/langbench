{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Protowire.Utf8
-- Description : Strict RFC 3629 UTF-8 validation.
module Protowire.Utf8 (isValidUtf8) where

import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

-- | Is the byte string well-formed UTF-8 per RFC 3629?  Overlong forms,
-- surrogates (U+D800–U+DFFF), code points above U+10FFFF and truncated
-- sequences are rejected.  Runs in a single pass.
isValidUtf8 :: ByteString -> Bool
isValidUtf8 bs = go 0
  where
    n = BS.length bs
    at :: Int -> Word8
    at = BU.unsafeIndex bs
    cont :: Int -> Bool
    cont i = i < n && at i .&. 0xC0 == 0x80
    go !i
      | i >= n = True
      | b < 0x80 = go (i + 1)
      | b < 0xC2 = False
      | b < 0xE0 = cont (i + 1) && go (i + 2)
      | b < 0xF0 =
          cont (i + 1) && cont (i + 2)
            && (let b1 = at (i + 1)
                 in (b /= 0xE0 || b1 >= 0xA0) && (b /= 0xED || b1 < 0xA0))
            && go (i + 3)
      | b < 0xF5 =
          cont (i + 1) && cont (i + 2) && cont (i + 3)
            && (let b1 = at (i + 1)
                 in (b /= 0xF0 || b1 >= 0x90) && (b /= 0xF4 || b1 < 0x90))
            && go (i + 4)
      | otherwise = False
      where
        b = at i

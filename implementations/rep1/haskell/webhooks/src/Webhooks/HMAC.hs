-- | HMAC-SHA-256 (RFC 2104), implemented on top of "Webhooks.SHA256".
module Webhooks.HMAC
  ( hmacSha256
  , constantTimeEq
  ) where

import Data.Bits (xor, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Webhooks.SHA256 (blockLength, sha256)

-- | @hmacSha256 key message@ is the 32-byte HMAC-SHA-256 of @message@ under
-- @key@. Keys of any length are accepted, including the empty key.
hmacSha256 :: ByteString -> ByteString -> ByteString
hmacSha256 key msg = sha256 (BS.append opad (sha256 (BS.append ipad msg)))
  where
    hashed = if BS.length key > blockLength then sha256 key else key
    padded = BS.append hashed (BS.replicate (blockLength - BS.length hashed) 0)
    ipad = BS.map (xor 0x36) padded
    opad = BS.map (xor 0x5c) padded

-- | Compare two byte strings without short-circuiting on the first
-- difference (the running time depends only on the lengths).
constantTimeEq :: ByteString -> ByteString -> Bool
constantTimeEq a b =
  BS.length a == BS.length b
    && BS.foldl' (.|.) 0 (BS.packZipWith xor a b) == 0

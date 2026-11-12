-- | Webhook secrets (@whsec_...@) and lists of them.
module Webhooks.Secret
  ( parseSecret
  , parseSecrets
  , maxSecrets
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Webhooks.Base64 (decode)

-- | Largest number of secrets in one list (key rotation).
maxSecrets :: Int
maxSecrets = 16

-- | Turn a secret into its raw HMAC key.
--
-- The secret is 1 to 512 printable ASCII characters (no comma). A leading
-- @whsec_@ is removed once; the rest is Base64-decoded. A remainder that is
-- not valid Base64, or that decodes to nothing, makes the secret invalid.
parseSecret :: ByteString -> Maybe ByteString
parseSecret s
  | n < 1 || n > 512 || not (BS.all ok s) = Nothing
  | otherwise = case decode (stripPrefix s) of
      Just key | not (BS.null key) -> Just key
      _ -> Nothing
  where
    n = BS.length s
    ok c = c >= 0x21 && c <= 0x7e && c /= 44
    prefix = BC.pack "whsec_"
    stripPrefix x
      | prefix `BS.isPrefixOf` x = BS.drop (BS.length prefix) x
      | otherwise = x

-- | Parse a comma-separated list of 1 to 'maxSecrets' secrets into raw keys,
-- preserving order.
parseSecrets :: ByteString -> Maybe [ByteString]
parseSecrets field
  | null entries || length entries > maxSecrets = Nothing
  | otherwise = traverse parseSecret entries
  where
    entries = BS.split 44 field

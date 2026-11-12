-- | The Standard Webhooks signature scheme: signing and verifying.
module Webhooks.Signature
  ( -- * Signing
    signedContent
  , signature
  , signatureHeader
    -- * Verifying
  , VerifyError (..)
  , verifyErrorText
  , verify
  , toleranceSeconds
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (find)
import Data.Maybe (mapMaybe)
import Webhooks.Base64 (decode, encodeStandard)
import Webhooks.Field (parseInt)
import Webhooks.HMAC (constantTimeEq, hmacSha256)

-- | The byte string that is signed: @id || "." || timestamp || "." || body@.
signedContent
  :: ByteString -- ^ message id
  -> ByteString -- ^ timestamp, as decimal text
  -> ByteString -- ^ payload
  -> ByteString
signedContent msgId ts body = BS.concat [msgId, dot, ts, dot, body]
  where
    dot = BC.singleton '.'

-- | One signature, @v1,<base64 of HMAC>@, for a raw key.
signature
  :: ByteString -- ^ raw key (see "Webhooks.Secret")
  -> ByteString -- ^ message id
  -> ByteString -- ^ timestamp text
  -> ByteString -- ^ payload
  -> ByteString
signature key msgId ts body =
  BS.append (BC.pack "v1,") (encodeStandard (hmacSha256 key (signedContent msgId ts body)))

-- | The @webhook-signature@ header value for a list of raw keys: one
-- signature per key, in order, joined by single spaces.
signatureHeader :: [ByteString] -> ByteString -> ByteString -> ByteString -> ByteString
signatureHeader keys msgId ts body = BS.intercalate (BC.singleton ' ') (map sign keys)
  where
    content = signedContent msgId ts body
    sign key = BS.append (BC.pack "v1,") (encodeStandard (hmacSha256 key content))

-- | Why a verification failed.
data VerifyError
  = MissingSignature
  | InvalidTimestamp
  | TimestampTooOld
  | TimestampTooNew
  | NoMatch
  deriving (Eq, Show, Enum, Bounded)

-- | The hyphenated name of a failure, e.g. @timestamp-too-old@.
verifyErrorText :: VerifyError -> ByteString
verifyErrorText e = BC.pack $ case e of
  MissingSignature -> "missing-signature"
  InvalidTimestamp -> "invalid-timestamp"
  TimestampTooOld -> "timestamp-too-old"
  TimestampTooNew -> "timestamp-too-new"
  NoMatch -> "no-match"

-- | Permitted clock difference in seconds (inclusive).
toleranceSeconds :: Int
toleranceSeconds = 300

-- | Verify a received webhook.
--
-- Steps, in order: the header must contain a non-empty token; the timestamp
-- must be a canonical integer; it must be within 'toleranceSeconds' of
-- @now@; and some @v1@ token must match the MAC of some key. On success the
-- result is @(i, j)@: the 0-based key index and header-token index of the
-- first match (keys are the outer loop). One MAC is computed per key.
verify
  :: [ByteString] -- ^ raw keys, in order
  -> ByteString   -- ^ received @webhook-id@
  -> ByteString   -- ^ received @webhook-timestamp@
  -> ByteString   -- ^ received @webhook-signature@
  -> ByteString   -- ^ body
  -> Int          -- ^ current time, Unix seconds
  -> Either VerifyError (Int, Int)
verify keys msgId tsText header body now
  | all BS.null tokens = Left MissingSignature
  | otherwise = case parseInt tsText of
      Nothing -> Left InvalidTimestamp
      Just ts
        | now - ts > toleranceSeconds -> Left TimestampTooOld
        | ts - now > toleranceSeconds -> Left TimestampTooNew
        | otherwise -> maybe (Left NoMatch) Right firstMatch
  where
    tokens = BS.split 32 header
    -- Decoded value of every well-formed @v1@ token, with its index.
    candidates = mapMaybe candidate (zip [0 ..] tokens)
    candidate (j, tok) = case BS.break (== 44) tok of
      (version, rest)
        | version == BC.pack "v1", Just (_, value) <- BS.uncons rest ->
            (,) j <$> decode value
      _ -> Nothing
    firstMatch = firstJust (zip [0 ..] keys) $ \(i, key) ->
      let mac = hmacSha256 key (signedContent msgId tsText body)
       in (,) i . fst <$> find (constantTimeEq mac . snd) candidates

firstJust :: [a] -> (a -> Maybe b) -> Maybe b
firstJust xs f = case mapMaybe f xs of
  (y : _) -> Just y
  [] -> Nothing

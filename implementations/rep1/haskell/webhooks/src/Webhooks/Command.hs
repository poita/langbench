-- | The line-oriented command interpreter behind the command-line tool.
--
-- Input is a stream of commands, one per line (see the README for the
-- grammar); output is one result per command, and @error@ for anything
-- malformed. Interpretation is total: no input makes it fail.
module Webhooks.Command
  ( processInput
  , runCommand
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import Webhooks.Base64 (decode, encodeStandard, encodeUrlSafe)
import Webhooks.Field (isBlank, parseId, parseInt, parseReceivedText, splitFields)
import Webhooks.HMAC (hmacSha256)
import Webhooks.Hex (encodeHex, parseHexField, renderHexField)
import Webhooks.SHA256 (sha256)
import Webhooks.Secret (parseSecret, parseSecrets)
import Webhooks.Signature (signatureHeader, verify, verifyErrorText)
import Webhooks.Simulator (renderResult, simulate)
import Webhooks.Simulator.Block (readBlock)

-- | Interpret a whole input (all of stdin) and produce the whole output.
processInput :: ByteString -> B.Builder
processInput = go . BC.split '\n'
  where
    go [] = mempty
    go (l : ls)
      | isBlank l = go ls
      | splitFields l == [BC.pack "simulate"] =
          let (block, rest) = readBlock ls
              out = case block of
                Just (eps, evs) -> renderResult (simulate eps evs)
                Nothing -> reply (BC.pack "error")
           in out <> go rest
      | otherwise = reply (runCommand l) <> go ls
    reply s = B.byteString s <> B.char7 '\n'

-- | Run one non-@simulate@ command line, returning its output line (without
-- the newline); @error@ if the line is malformed.
runCommand :: ByteString -> ByteString
runCommand line = maybe err id (dispatch (splitFields line))
  where
    err = BC.pack "error"

dispatch :: [ByteString] -> Maybe ByteString
dispatch fields = case map BC.unpack (take 1 fields) of
  ["sha256"] | [_, h] <- fields -> do
    bytes <- parseHexField h
    Just (encodeHex (sha256 bytes))
  ["hmac"] | [_, k, m] <- fields -> do
    key <- parseHexField k
    msg <- parseHexField m
    Just (encodeHex (hmacSha256 key msg))
  ["b64enc"] | [_, h] <- fields -> do
    bytes <- parseHexField h
    Just (dash (encodeStandard bytes))
  ["b64urlenc"] | [_, h] <- fields -> do
    bytes <- parseHexField h
    Just (dash (encodeUrlSafe bytes))
  ["b64dec"] | [_, h] <- fields -> do
    text <- parseHexField h
    renderHexField <$> decode text
  ["secret"] | [_, s] <- fields -> do
    key <- parseSecret s
    Just (encodeHex key)
  ["sign"] | [_, ss, ident, ts, p] <- fields -> do
    keys <- parseSecrets ss
    msgId <- parseId ident
    _ <- parseInt ts
    body <- parseHexField p
    Just (signatureHeader keys msgId ts body)
  ["verify"] | [_, ss, ident, ts, nowText, h, p] <- fields -> do
    keys <- parseSecrets ss
    msgId <- parseId ident
    tsText <- parseReceivedText ts
    now <- parseInt nowText
    header <- parseHexField h
    body <- parseHexField p
    Just $ case verify keys msgId tsText header body now of
      Right (i, j) -> BC.pack ("ok " ++ show i ++ " " ++ show j)
      Left e -> BS.append (BC.pack "fail ") (verifyErrorText e)
  _ -> Nothing
  where
    dash s = if BS.null s then BC.singleton '-' else s

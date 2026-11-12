-- | Standard Webhooks signing and verification, with SHA-256, HMAC-SHA-256 and
-- Base64 implemented from scratch, and a deterministic delivery simulator.
--
-- This module re-exports the commonly used parts of the library:
--
-- * "Webhooks.SHA256", "Webhooks.HMAC", "Webhooks.Base64", "Webhooks.Hex":
--   primitives;
-- * "Webhooks.Secret": @whsec_@ secrets and key lists;
-- * "Webhooks.Signature": 'signatureHeader' and 'verify';
-- * "Webhooks.Simulator": 'simulate' and its types;
-- * "Webhooks.Command": the command interpreter used by the CLI.
--
-- > import Webhooks
-- > let Just keys = parseSecrets (BC.pack "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
-- >     hdr = signatureHeader keys (BC.pack "msg_1") (BC.pack "1614265330") body
-- > verify keys (BC.pack "msg_1") (BC.pack "1614265330") hdr body 1614265400
-- > -- Right (0,0)
module Webhooks
  ( module Webhooks.SHA256
  , module Webhooks.HMAC
  , module Webhooks.Base64
  , module Webhooks.Hex
  , module Webhooks.Secret
  , module Webhooks.Signature
  , module Webhooks.Simulator
  , module Webhooks.Simulator.Block
  , module Webhooks.Command
  ) where

import Webhooks.Base64
import Webhooks.Command
import Webhooks.HMAC
import Webhooks.Hex
import Webhooks.SHA256
import Webhooks.Secret
import Webhooks.Signature
import Webhooks.Simulator
import Webhooks.Simulator.Block

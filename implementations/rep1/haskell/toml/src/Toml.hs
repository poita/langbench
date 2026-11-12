-- | A TOML 1.0.0 parser and canonical serializer.
--
-- > import qualified Toml
-- >
-- > case Toml.decodeText "answer = 42\n[owner]\nname = \"Tom\"\n" of
-- >   Left err  -> putStrLn (Toml.renderDecodeError err)
-- >   Right doc -> Data.ByteString.Builder.hPutBuilder stdout (Toml.renderTaggedJson doc)
--
-- The modules behind this one:
--
-- * "Toml.Value": the document model;
-- * "Toml.Decode": TOML text to 'Value';
-- * "Toml.Encode": 'Value' to canonical TOML text;
-- * "Toml.Json": the toml-test tagged JSON representation.
module Toml
  ( -- * Document model
    Value (..)
  , Table
  , ScalarType (..)
  , vString, vInteger, vFloat, vBool
    -- * Decoding
  , decode
  , decodeText
  , DecodeError (..)
  , renderDecodeError
    -- * Encoding
  , encode
  , encodeText
    -- * Tagged JSON
  , renderTaggedJson
  , parseTaggedJson
  ) where

import Toml.Decode
import Toml.Encode
import Toml.Json
import Toml.Value

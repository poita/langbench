-- |
-- Module      : Protowire
-- Description : Protobuf-style wire codec with a canonical text form.
--
-- A minimal end-to-end example:
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > import Protowire
-- >
-- > main :: IO ()
-- > main = do
-- >   let Right schema = parseSchema "message M { int32 a = 1; repeated string s = 2; }"
-- >       Just m = lookupMessage "M" schema
-- >   -- text -> wire bytes -> text
-- >   let Right msg   = parseText m "{s: [\"hi\"], a: 150}"
-- >       Right bytes = encode m msg           -- 08 96 01 12 02 68 69
-- >       Right msg'  = decode m (toStrict bytes)
-- >   print (renderText m msg')                -- {a: 150, s: ["hi"]}
--
-- The pieces live in their own modules; this one re-exports the everyday
-- API.
module Protowire
  ( -- * Schemas
    Schema
  , MessageDesc (..)
  , FieldDesc (..)
  , FieldType (..)
  , ScalarType (..)
  , SchemaError (..)
  , parseSchema
  , lookupMessage
  , messageNames
    -- * Messages
  , Message (..)
  , Slot (..)
  , Value (..)
  , emptyMessage
  , normalize
    -- * Wire format
  , decode
  , encode
  , WireError (..)
  , EncodeError (..)
    -- * Text form
  , parseText
  , renderText
  , TextError (..)
    -- * Requests (CLI protocol)
  , processInput
  , runRequest
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import Protowire.Decode (decodeMessage)
import Protowire.Encode (EncodeError (..), encodeMessage)
import Protowire.Request (processInput, runRequest)
import Protowire.Schema
import Protowire.Text.Parse (TextError (..), parseMessage)
import Protowire.Text.Render (renderMessage)
import Protowire.Value
import Protowire.Wire (WireError (..))

-- | Decode wire bytes as the given message type.
decode :: MessageDesc -> ByteString -> Either WireError Message
decode = decodeMessage

-- | Encode a message to its canonical wire bytes.
encode :: MessageDesc -> Message -> Either EncodeError BL.ByteString
encode = encodeMessage

-- | Parse the text form (see "Protowire.Text.Parse").
parseText :: MessageDesc -> ByteString -> Either TextError Message
parseText = parseMessage

-- | Render the canonical text form as a lazy byte string.
renderText :: MessageDesc -> Message -> BL.ByteString
renderText d = B.toLazyByteString . renderMessage d

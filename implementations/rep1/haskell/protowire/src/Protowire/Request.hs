-- |
-- Module      : Protowire.Request
-- Description : The line-oriented request protocol used by the CLI.
--
-- Input is a schema, a line @--@, then one request per line:
--
-- > decode <Name> <hex>
-- > encode <Name> <text>
--
-- Every request yields exactly one output line: the result, or @error@.
module Protowire.Request
  ( processInput
  , runRequest
  , splitInput
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder, char7, string7)
import Protowire.Decode (decodeMessage)
import Protowire.Encode (encodeMessage)
import Protowire.Hex
import Protowire.Schema
import Protowire.Text.Parse (parseMessage)
import Protowire.Text.Render (renderMessage)

-- | Split program input into schema text and request lines.  The schema is
-- everything before the first line that is exactly @--@.
splitInput :: ByteString -> (ByteString, [ByteString])
splitInput input = go 0 (BC.lines input)
  where
    go _ [] = (input, [])
    go off (l : ls)
      | l == BC.pack "--" = (BS.take off input, ls)
      | otherwise = go (off + BS.length l + 1) ls

-- | Run every request in the input against its schema, producing the whole
-- output (one @\\n@-terminated line per request).  'Left' if the schema does
-- not parse.
processInput :: ByteString -> Either SchemaError Builder
processInput input = do
  let (schemaText, reqs) = splitInput input
  schema <- parseSchema schemaText
  Right (foldMap (\r -> runRequest schema r <> char7 '\n') reqs)

-- | Run one request line, returning the output line without its newline.
-- Any failure is reported as @error@.
runRequest :: Schema -> ByteString -> Builder
runRequest schema line = maybe (string7 "error") id result
  where
    (verb, afterVerb) = BC.break (== ' ') line
    (name, rest) = BC.break (== ' ') (BS.drop 1 afterVerb)
    result
      | BS.null afterVerb = Nothing
      | verb == BC.pack "decode" = lookupMessage name schema >>= \d -> doDecode d rest
      | verb == BC.pack "encode" = lookupMessage name schema >>= \d -> doEncode d rest
      | otherwise = Nothing

doDecode :: MessageDesc -> ByteString -> Maybe Builder
doDecode d rest = do
  hex <- case BC.uncons rest of
    Nothing -> Just BS.empty
    Just (' ', h) | not (BS.null h) -> Just h
    _ -> Nothing
  bytes <- decodeHex hex
  either (const Nothing) (Just . renderMessage d) (decodeMessage d bytes)

doEncode :: MessageDesc -> ByteString -> Maybe Builder
doEncode d rest = do
  text <- case BC.uncons rest of
    Just (' ', t) -> Just t
    _ -> Nothing
  msg <- either (const Nothing) Just (parseMessage d text)
  bytes <- either (const Nothing) Just (encodeMessage d msg)
  Just (encodeHexLazy bytes)

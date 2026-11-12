{-# LANGUAGE OverloadedStrings #-}
-- | The tagged JSON interchange format of the toml-test suite.
--
-- A table is a JSON object, an array is a JSON array, and a scalar is an
-- object @{"type": …, "value": …}@ whose two members are strings.
module Toml.Json
  ( renderTaggedJson
  , parseTaggedJson
  ) where

import Control.Monad (when)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString.Builder (Builder, char7, string7)
import Data.Char (chr, digitToInt, isHexDigit)
import Data.List (intersperse)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)

import Toml.Internal.Builder (escapeText, hexEscape)
import Toml.Internal.Parser
import Toml.Value

------------------------------------------------------------------------------
-- Writing

-- | Render a table as compact, key-sorted tagged JSON (no trailing newline).
renderTaggedJson :: Table -> Builder
renderTaggedJson = table

table :: Table -> Builder
table m = char7 '{' <> mconcat (intersperse (char7 ',') [str k <> char7 ':' <> value v | (k, v) <- Map.toAscList m]) <> char7 '}'

value :: Value -> Builder
value (VScalar ty t) =
  string7 "{\"type\":" <> str (scalarTypeName ty) <> string7 ",\"value\":" <> str t <> char7 '}'
value (VArray vs) = char7 '[' <> mconcat (intersperse (char7 ',') (map value vs)) <> char7 ']'
value (VTable m) = table m

str :: Text -> Builder
str t = char7 '"' <> escapeText needs esc t <> char7 '"'
  where
    needs c = c == '"' || c == '\\' || c < ' '
    esc c = case c of
      '"' -> string7 "\\\""
      '\\' -> string7 "\\\\"
      '\b' -> string7 "\\b"
      '\f' -> string7 "\\f"
      '\n' -> string7 "\\n"
      '\r' -> string7 "\\r"
      '\t' -> string7 "\\t"
      _ -> hexEscape c

------------------------------------------------------------------------------
-- Reading

data Json
  = JObject [(Text, Json)]
  | JArray [Json]
  | JString Text
  | JOther

-- | Parse tagged JSON (members in any order, arbitrary whitespace) into a
-- table.  A JSON object is a scalar exactly when it has the two string
-- members @type@ and @value@ and @type@ names one of the eight types.
parseTaggedJson :: ByteString -> Either String Table
parseTaggedJson bs = case runP (ws *> jsonValue <* ws) (decodeUtf8With lenientDecode bs) of
  Fail m _ -> Left m
  Ok j rest
    | T.null rest -> toValue j >>= \v -> case v of
        VTable t -> Right t
        _ -> Left "root is not an object"
    | otherwise -> Left "trailing characters after JSON value"

toValue :: Json -> Either String Value
toValue (JString _) = Left "bare string where a node was expected"
toValue JOther = Left "unexpected JSON value"
toValue (JArray js) = VArray <$> mapM toValue js
toValue (JObject ms) = case scalar of
  Just v -> Right v
  Nothing -> VTable . Map.fromList <$> mapM (\(k, j) -> (,) k <$> toValue j) ms
  where
    scalar = case ms of
      [(a, JString x), (b, JString y)]
        | a == "type", b == "value" -> mk x y
        | a == "value", b == "type" -> mk y x
      _ -> Nothing
    mk ty v = (\t -> VScalar t v) <$> scalarTypeFromName ty

isJsonWs :: Char -> Bool
isJsonWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

ws :: P ()
ws = skipWhileP isJsonWs

jsonValue :: P Json
jsonValue = do
  mc <- peekChar
  case mc of
    Just '{' -> dropP 1 *> ws *> object
    Just '[' -> dropP 1 *> ws *> array
    Just '"' -> JString <$> jsonString
    Just _ -> do
      _ <- takeWhileP (\c -> not (isJsonWs c) && c /= ',' && c /= '}' && c /= ']')
      pure JOther
    Nothing -> failP "unexpected end of JSON"

object :: P Json
object = do
  mc <- peekChar
  if mc == Just '}' then dropP 1 *> pure (JObject []) else JObject <$> members
  where
    members = do
      k <- jsonString
      ws
      expectChar ':'
      ws
      v <- jsonValue
      ws
      c <- nextChar
      case c of
        ',' -> ws *> (((k, v) :) <$> members)
        '}' -> pure [(k, v)]
        _ -> failP "expected ',' or '}'"

array :: P Json
array = do
  mc <- peekChar
  if mc == Just ']' then dropP 1 *> pure (JArray []) else JArray <$> elements
  where
    elements = do
      v <- jsonValue
      ws
      c <- nextChar
      case c of
        ',' -> ws *> ((v :) <$> elements)
        ']' -> pure [v]
        _ -> failP "expected ',' or ']'"

jsonString :: P Text
jsonString = expectChar '"' >> go []
  where
    go acc = do
      chunk <- takeWhileP (\c -> c /= '"' && c /= '\\')
      c <- nextChar
      case c of
        '"' -> pure (T.concat (reverse (chunk : acc)))
        _ -> do
          e <- escape
          go (e : chunk : acc)
    escape = do
      c <- nextChar
      case c of
        '"' -> pure "\""
        '\\' -> pure "\\"
        '/' -> pure "/"
        'b' -> pure "\b"
        'f' -> pure "\f"
        'n' -> pure "\n"
        'r' -> pure "\r"
        't' -> pure "\t"
        'u' -> do
          hi <- hex4
          if hi >= 0xD800 && hi < 0xDC00
            then do
              expectText "\\u"
              lo <- hex4
              when (lo < 0xDC00 || lo > 0xDFFF) (failP "bad low surrogate")
              pure (T.singleton (chr (0x10000 + ((hi - 0xD800) `shiftL` 10 .|. (lo - 0xDC00)))))
            else if hi >= 0xDC00 && hi <= 0xDFFF
              then failP "lone low surrogate"
              else pure (T.singleton (chr hi))
        _ -> failP "bad JSON escape"
    hex4 = do
      ds <- T.unpack <$> takeN 4
      when (not (all isHexDigit ds)) (failP "bad \\u escape")
      pure (foldl (\a d -> a * 16 + digitToInt d) 0 ds)


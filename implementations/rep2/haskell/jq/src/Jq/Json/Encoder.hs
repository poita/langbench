-- | Compact JSON serialisation.
module Jq.Json.Encoder
  ( encodeValue
  , encodeText
  , renderValue
  , renderValueText
  ) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import Data.Foldable (toList)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Numeric (showHex)

import Jq.Number (numberBuilder)
import Jq.Value

-- | Compact JSON for a value: no whitespace, objects in insertion order,
-- strings escaped as in jq (control characters and U+007F as @\\u00XX@).
encodeValue :: Value -> BB.Builder
encodeValue v = case v of
  VNull -> BB.string7 "null"
  VBool True -> BB.string7 "true"
  VBool False -> BB.string7 "false"
  VNum d -> numberBuilder d
  VStr t -> encodeText t
  VArr xs -> BB.char7 '[' <> commaSep (map encodeValue (toList xs)) <> BB.char7 ']'
  VObj o -> BB.char7 '{' <> commaSep [encodeText k <> BB.char7 ':' <> encodeValue x | (k, x) <- objectToList o] <> BB.char7 '}'

commaSep :: [BB.Builder] -> BB.Builder
commaSep [] = mempty
commaSep (x : xs) = x <> foldr (\b r -> BB.char7 ',' <> b <> r) mempty xs

-- | A quoted, escaped JSON string.
encodeText :: Text -> BB.Builder
encodeText t
  | T.all plain t = BB.char7 '"' <> TE.encodeUtf8Builder t <> BB.char7 '"'
  | otherwise = BB.char7 '"' <> T.foldr (\c r -> esc c <> r) mempty t <> BB.char7 '"'
  where
    plain c = c >= ' ' && c /= '"' && c /= '\\' && c /= '\DEL'
    esc c = case c of
      '"' -> BB.string7 "\\\""
      '\\' -> BB.string7 "\\\\"
      '\b' -> BB.string7 "\\b"
      '\f' -> BB.string7 "\\f"
      '\n' -> BB.string7 "\\n"
      '\r' -> BB.string7 "\\r"
      '\t' -> BB.string7 "\\t"
      _ | c < ' ' || c == '\DEL' ->
            let h = showHex (ord c) "" in BB.string7 ("\\u" ++ replicate (4 - length h) '0' ++ h)
        | otherwise -> BB.charUtf8 c

-- | Compact JSON as a lazy 'BL.ByteString'.
renderValue :: Value -> BL.ByteString
renderValue = BB.toLazyByteString . encodeValue

-- | Compact JSON as 'Text' (what @tostring@ yields for non-strings).
renderValueText :: Value -> Text
renderValueText = TE.decodeUtf8 . BL.toStrict . renderValue

-- | Compact JSON serialisation.
module Jq.Json.Render
  ( renderValue
  , renderStrict
  , renderText
  ) where

import qualified Data.ByteString as B
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Data.Foldable (toList)
import Jq.Number (renderDouble)
import Jq.Value

-- | Serialise a value as compact JSON (no whitespace; object keys in
-- insertion order).
renderValue :: Value -> Builder
renderValue v = case v of
  VNull -> string7 "null"
  VBool True -> string7 "true"
  VBool False -> string7 "false"
  VNumber n -> renderDouble n
  VString s -> renderString s
  VArray a -> char7 '[' <> commaSep renderValue (toList a) <> char7 ']'
  VObject o -> char7 '{' <> commaSep entry (objToList o) <> char7 '}'
  where
    entry (k, x) = renderString k <> char7 ':' <> renderValue x

commaSep :: (a -> Builder) -> [a] -> Builder
commaSep _ [] = mempty
commaSep f (x : xs) = f x <> mconcat [char7 ',' <> f y | y <- xs]

renderString :: Text -> Builder
renderString s
  | T.all plain s = char7 '"' <> TE.encodeUtf8Builder s <> char7 '"'
  | otherwise = char7 '"' <> T.foldr (\c r -> esc c <> r) mempty s <> char7 '"'
  where
    plain c = c >= ' ' && c /= '"' && c /= '\\' && c /= '\DEL'
    esc c = case c of
      '"' -> string7 "\\\""
      '\\' -> string7 "\\\\"
      '\b' -> string7 "\\b"
      '\f' -> string7 "\\f"
      '\n' -> string7 "\\n"
      '\r' -> string7 "\\r"
      '\t' -> string7 "\\t"
      _
        | plain c -> charUtf8 c
        | otherwise -> string7 "\\u" <> word16HexFixed (fromIntegral (ord c))

-- | Serialise to a strict 'B.ByteString'.
renderStrict :: Value -> B.ByteString
renderStrict = BL.toStrict . toLazyByteString . renderValue

-- | Serialise to 'Text'.
renderText :: Value -> Text
renderText = TE.decodeUtf8With TE.lenientDecode . renderStrict

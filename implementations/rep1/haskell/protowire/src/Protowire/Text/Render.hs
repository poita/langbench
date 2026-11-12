-- |
-- Module      : Protowire.Text.Render
-- Description : Canonical text form of a 'Message'.
--
-- > {a: 1, b: "x", c: [1, 2], d: {v: -5}}
module Protowire.Text.Render
  ( renderMessage
  , renderValue
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder
import Data.Foldable (toList)
import qualified Data.IntMap.Strict as IM
import Data.List (intersperse)
import Data.Word (Word8)
import Protowire.Hex (encodeHex)
import Protowire.Schema
import Protowire.Value

-- | Render a message in canonical form: fields in increasing field-number
-- order, default singular scalars and empty repeated fields omitted, present
-- sub-messages kept (@d: {}@).  Fields unknown to the schema are ignored.
renderMessage :: MessageDesc -> Message -> Builder
renderMessage desc (Message fields) =
  char7 '{' <> commaSep (concatMap one (IM.toAscList fields)) <> char7 '}'
  where
    one (num, slot) = case IM.lookup num (msgByNumber desc) of
      Nothing -> []
      Just fd -> case slot of
        Single v
          | isDefault v -> []
          | otherwise -> [named fd (renderValue (fieldType fd) v)]
        Repeated vs
          | null vs -> []
          | otherwise ->
              [named fd (char7 '[' <> commaSep (map (renderValue (fieldType fd)) (toList vs)) <> char7 ']')]
    named fd b = byteString (fieldName fd) <> string7 ": " <> b

-- | Render one value of the given type.  The type only matters for messages,
-- whose fields are named by the schema.
renderValue :: FieldType -> Value -> Builder
renderValue ty v = case v of
  VInt n -> int64Dec n
  VWord n -> word64Dec n
  VBool b -> string7 (if b then "true" else "false")
  VString s -> char7 '"' <> escape s <> char7 '"'
  VBytes s -> string7 "x\"" <> encodeHex s <> char7 '"'
  VMessage m -> case ty of
    FMessage d -> renderMessage d m
    FScalar _ -> string7 "{}"

commaSep :: [Builder] -> Builder
commaSep = mconcat . intersperse (string7 ", ")

-- Escape string bytes; non-ASCII UTF-8 bytes pass through unchanged.
escape :: ByteString -> Builder
escape s
  | BS.null s = mempty
  | otherwise =
      let (plain, rest) = BS.span (not . special) s
       in byteString plain <> case BS.uncons rest of
            Nothing -> mempty
            Just (w, rest') -> esc w <> escape rest'
  where
    special :: Word8 -> Bool
    special w = w < 0x20 || w == 0x22 || w == 0x5c || w == 0x7f
    esc w = case w of
      0x22 -> string7 "\\\""
      0x5c -> string7 "\\\\"
      0x0a -> string7 "\\n"
      0x0d -> string7 "\\r"
      0x09 -> string7 "\\t"
      _ -> string7 "\\x" <> word8HexFixed w

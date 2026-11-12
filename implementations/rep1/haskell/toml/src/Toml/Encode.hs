{-# LANGUAGE OverloadedStrings #-}
-- | The canonical TOML serializer.
--
-- The output is fully determined by the input tree, so that two correct
-- implementations produce identical bytes:
--
-- * in every table, key/value pairs come first and sub-table headers after,
--   each group in ascending key order (Unicode code point order);
-- * a non-empty array of tables is written as @[[header]]@ sections, every
--   other array inline as @[1, 2]@;
-- * every table gets its own header (even an empty one), preceded by a blank
--   line unless it is the first line of the document;
-- * strings are always basic strings with minimal escaping.
--
-- @'Toml.Decode.decodeText' . 'encode'@ reproduces the original tree.
module Toml.Encode
  ( encode
  , encodeText
  ) where

import Data.ByteString.Builder (Builder, char7, string7, toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (intersperse)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8Builder, decodeUtf8)

import Toml.Internal.Builder (escapeText, hexEscape)
import Toml.Value

-- | Render a table as a TOML document (UTF-8, ending in a newline).
encode :: Table -> Builder
encode root = case go False [] root of
  (False, _) -> char7 '\n'
  (True, b) -> b

-- | 'encode' as strict text.
encodeText :: Table -> Text
encodeText = decodeUtf8 . BL.toStrict . toLazyByteString . encode

-- | Is this value rendered as a sub-table (@[header]@)?
isSubTable :: Value -> Bool
isSubTable (VTable _) = True
isSubTable _ = False

-- | Is this value rendered as @[[header]]@ sections?
isTableArray :: Value -> Bool
isTableArray (VArray vs@(_ : _)) = all isSubTable vs
isTableArray _ = False

-- | Render a table below the given (already rendered) path.  The flag says
-- whether anything has been written to the document yet, and is returned
-- updated together with the output.
go :: Bool -> [Builder] -> Table -> (Bool, Builder)
go written path tbl = (written' , pairs <> sections)
  where
    entries = Map.toAscList tbl
    inlineEntries = [(k, v) | (k, v) <- entries, not (isSubTable v), not (isTableArray v)]
    headerEntries = [(k, v) | (k, v) <- entries, isSubTable v || isTableArray v]
    pairs = mconcat [key k <> string7 " = " <> inline v <> char7 '\n' | (k, v) <- inlineEntries]
    (written', sections) =
      foldl section (written || not (null inlineEntries), mempty) headerEntries

    -- Render one sub-table or array of tables; any header marks the document
    -- as non-empty for the blank-line rule.
    section (w, acc) (k, v) = case v of
      VTable t -> (True, acc <> block w "[" "]" k t)
      VArray ts -> (True, snd (foldl (element k) (w, acc) ts))
      _ -> (w, acc)

    element k (w, acc) (VTable t) = (True, acc <> block w "[[" "]]" k t)
    element _ st _ = st

    block w open close k t =
      let path' = path ++ [key k]
          header = mconcat (intersperse (char7 '.') path')
      in (if w then char7 '\n' else mempty)
           <> string7 open <> header <> string7 close <> char7 '\n'
           <> snd (go True path' t)

key :: Text -> Builder
key k
  | not (T.null k) && T.all bare k = encodeUtf8Builder k
  | otherwise = quote k
  where bare c = isAsciiLower c || isAsciiUpper c || (isDigit c && c < '\x80') || c == '_' || c == '-'

quote :: Text -> Builder
quote t = char7 '"' <> escapeText needs esc t <> char7 '"'
  where
    needs c = c == '"' || c == '\\' || c < ' ' || c == '\DEL'
    esc c = case c of
      '"' -> string7 "\\\""
      '\\' -> string7 "\\\\"
      '\b' -> string7 "\\b"
      '\t' -> string7 "\\t"
      '\n' -> string7 "\\n"
      '\f' -> string7 "\\f"
      '\r' -> string7 "\\r"
      _ -> hexEscape c

inline :: Value -> Builder
inline (VScalar TString t) = quote t
inline (VScalar _ t) = encodeUtf8Builder t
inline (VArray vs) = char7 '[' <> mconcat (intersperse (string7 ", ") (map inline vs)) <> char7 ']'
inline (VTable m) =
  char7 '{' <> mconcat (intersperse (string7 ", ") [key k <> string7 " = " <> inline v | (k, v) <- Map.toAscList m]) <> char7 '}'

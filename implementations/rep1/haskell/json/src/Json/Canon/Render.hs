{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Json.Canon.Render
-- Description : Canonical serialisation of a JSON tree.
module Json.Canon.Render
  ( render
  , renderString
  , normalizeMembers
  ) where

import Data.ByteString.Builder (Builder, char7, string7, word8)
import Data.List (sortBy)
import Data.Text (Text)
import Data.Text.Array (unsafeIndex)
import qualified Data.Text.Encoding as TE
import Data.Text.Internal (Text (..))
import Data.Word (Word8)

import Json.Canon.Key (compareKeys)
import Json.Canon.Types

-- | Canonical serialisation of a value, written once into a single
-- 'Builder' (no per-subtree intermediate output, so the cost is linear in
-- the output apart from key sorting).
--
-- * no whitespace outside strings;
-- * object members sorted by key in UTF-16 code unit order, with only the
--   last member of each duplicated key kept;
-- * strings escape only @\"@, @\\@ and control characters below U+0020.
render :: Value -> Builder
render v = case v of
  Null -> string7 "null"
  Bool True -> string7 "true"
  Bool False -> string7 "false"
  Number t -> TE.encodeUtf8Builder t
  String t -> renderString t
  Array [] -> string7 "[]"
  Array (x : xs) -> char7 '[' <> render x <> foldr (\e r -> char7 ',' <> render e <> r) (char7 ']') xs
  Object ms -> case normalizeMembers ms of
    [] -> string7 "{}"
    (m : rest) -> char7 '{' <> member m <> foldr (\e r -> char7 ',' <> member e <> r) (char7 '}') rest
  where
    member (k, x) = renderString k <> char7 ':' <> render x

-- | Sort members by key (stable, UTF-16 order) and keep the last member of
-- each run of equal keys.
normalizeMembers :: [(Text, Value)] -> [(Text, Value)]
normalizeMembers [] = []
normalizeMembers ms@[_] = ms
normalizeMembers ms = dedup (sortBy (\a b -> compareKeys (fst a) (fst b)) ms)
  where
    dedup (x : rest@(y : _))
      | fst x == fst y = dedup rest
      | otherwise = x : dedup rest
    dedup xs = xs

-- | A string in canonical quoted form.
renderString :: Text -> Builder
renderString (Text arr off len) = char7 '"' <> go 0 0
  where
    go :: Int -> Int -> Builder
    go !start !i
      | i >= len = run start i <> char7 '"'
      | b == 0x22 = run start i <> string7 "\\\"" <> go (i + 1) (i + 1)
      | b == 0x5C = run start i <> string7 "\\\\" <> go (i + 1) (i + 1)
      | b < 0x20 = run start i <> control b <> go (i + 1) (i + 1)
      | otherwise = go start (i + 1)
      where
        b = unsafeIndex arr (off + i)
    -- A run of bytes needing no escape; its end points are character
    -- boundaries because escapes are ASCII.
    run s e
      | s == e = mempty
      | otherwise = TE.encodeUtf8Builder (Text arr (off + s) (e - s))

control :: Word8 -> Builder
control b = case b of
  0x08 -> string7 "\\b"
  0x0C -> string7 "\\f"
  0x0A -> string7 "\\n"
  0x0D -> string7 "\\r"
  0x09 -> string7 "\\t"
  _ -> string7 "\\u00" <> word8 (hexDigit (b `div` 16)) <> word8 (hexDigit (b `mod` 16))
  where
    hexDigit d = if d < 10 then 0x30 + d else 0x61 + d - 10

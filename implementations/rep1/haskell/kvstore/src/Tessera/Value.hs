{-# LANGUAGE OverloadedStrings #-}

-- | The document value model of SPEC §4: six kinds of value, their binary
-- serialisation and their canonical one-line rendering.
module Tessera.Value
  ( Value (..)
  , typeRank
  , depth
  , serialize
  , serializeBuilder
  , deserialize
  , render
  , renderBuilder
  , renderString
  ) where

import qualified Data.ByteString as BS
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Tessera.Binary (be32, be64)

-- | A document value.  Strings are kept as UTF-8 bytes; objects keep their
-- fields in ascending byte-wise name order (the order of 'Map').
data Value
  = VNull
  | VBool !Bool
  | VInt !Int64
  | VString !BS.ByteString
  | VList [Value]
  | VObject !(Map BS.ByteString Value)
  deriving (Eq, Show)

-- | The type rank of SPEC §4: null 0, bool 1, int 2, string 3, list 4, object 5.
typeRank :: Value -> Int
typeRank v = case v of
  VNull -> 0
  VBool _ -> 1
  VInt _ -> 2
  VString _ -> 3
  VList _ -> 4
  VObject _ -> 5

-- | Nesting depth (SPEC §4.1): 1 for scalars and for empty containers.
depth :: Value -> Int
depth v = case v of
  VList xs -> 1 + maximum (0 : map depth xs)
  VObject m -> 1 + maximum (0 : map depth (Map.elems m))
  _ -> 1

strictly :: Builder -> BS.ByteString
strictly = LBS.toStrict . toLazyByteString

-- | Serialised form (SPEC §4.2).
serialize :: Value -> BS.ByteString
serialize = strictly . serializeBuilder

serializeBuilder :: Value -> Builder
serializeBuilder v = case v of
  VNull -> word8 0
  VBool False -> word8 1
  VBool True -> word8 2
  VInt i -> word8 3 <> int64BE i
  VString s -> word8 4 <> len32 (BS.length s) <> byteString s
  VList xs -> word8 5 <> len32 (length xs) <> foldMap serializeBuilder xs
  VObject m ->
    word8 6 <> len32 (Map.size m)
      <> mconcat [len32 (BS.length k) <> byteString k <> serializeBuilder x | (k, x) <- Map.toAscList m]
  where
    len32 = word32BE . fromIntegral

-- | Inverse of 'serialize'.  Returns 'Nothing' for malformed or trailing input.
deserialize :: BS.ByteString -> Maybe Value
deserialize bs = case decode bs of
  Just (v, rest) | BS.null rest -> Just v
  _ -> Nothing

decode :: BS.ByteString -> Maybe (Value, BS.ByteString)
decode bs = do
  (t, r) <- BS.uncons bs
  case t of
    0 -> Just (VNull, r)
    1 -> Just (VBool False, r)
    2 -> Just (VBool True, r)
    3 | BS.length r >= 8 -> Just (VInt (fromIntegral (be64 r 0)), BS.drop 8 r)
    4 -> do
      (n, r') <- count r
      bytes r' n >>= \(s, r'') -> Just (VString s, r'')
    5 -> do
      (n, r') <- count r
      items n r' []
    6 -> do
      (n, r') <- count r
      fields n r' Map.empty
    _ -> Nothing
  where
    count r
      | BS.length r >= 4 = Just (be32 r 0, BS.drop 4 r)
      | otherwise = Nothing
    bytes r n
      | BS.length r >= n = Just (BS.splitAt n r)
      | otherwise = Nothing
    items :: Int -> BS.ByteString -> [Value] -> Maybe (Value, BS.ByteString)
    items 0 r acc = Just (VList (reverse acc), r)
    items n r acc = do
      (x, r') <- decode r
      items (n - 1) r' (x : acc)
    fields :: Int -> BS.ByteString -> Map BS.ByteString Value -> Maybe (Value, BS.ByteString)
    fields 0 r acc = Just (VObject acc, r)
    fields n r acc = do
      (kl, r1) <- count r
      (k, r2) <- bytes r1 kl
      (x, r3) <- decode r2
      fields (n - 1) r3 (Map.insert k x acc)

-- | Canonical rendering (SPEC §4.4) as a strict byte string.
render :: Value -> BS.ByteString
render = strictly . renderBuilder

-- | Canonical rendering as a 'Builder'.
renderBuilder :: Value -> Builder
renderBuilder v = case v of
  VNull -> "null"
  VBool False -> "false"
  VBool True -> "true"
  VInt i -> int64Dec i
  VString s -> renderString s
  VList xs -> char7 '[' <> commaSep (map renderBuilder xs) <> char7 ']'
  VObject m ->
    char7 '{'
      <> commaSep [renderString k <> char7 ':' <> renderBuilder x | (k, x) <- Map.toAscList m]
      <> char7 '}'
  where
    commaSep [] = mempty
    commaSep (x : xs) = x <> mconcat [char7 ',' <> y | y <- xs]

-- | A quoted, escaped string (SPEC §4.5).  Only ASCII needs escaping, so the
-- UTF-8 bytes can be processed one at a time.
renderString :: BS.ByteString -> Builder
renderString s = char7 '"' <> BS.foldr (\b acc -> esc b <> acc) mempty s <> char7 '"'
  where
    esc :: (Integral a) => a -> Builder
    esc b = case b of
      0x22 -> "\\\""
      0x5C -> "\\\\"
      0x08 -> "\\b"
      0x09 -> "\\t"
      0x0A -> "\\n"
      0x0C -> "\\f"
      0x0D -> "\\r"
      _
        | b < 0x20 || b == 0x7F -> "\\u00" <> hexDigit (fromIntegral b `div` 16) <> hexDigit (fromIntegral b `mod` 16)
        | otherwise -> word8 (fromIntegral b)
    hexDigit :: Int -> Builder
    hexDigit d = char7 ("0123456789abcdef" !! d)

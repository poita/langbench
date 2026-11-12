{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Json.Canon.Parser
-- Description : Strict single-pass recursive-descent JSON parser.
module Json.Canon.Parser
  ( parse
  , maxDepth
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)

import Json.Canon.Types
import Json.Canon.Utf8 (validateUtf8)

-- | Maximum supported nesting depth of arrays and objects. A container at
-- depth 513 or more is rejected.
maxDepth :: Int
maxDepth = 512

-- | Parse one complete JSON document (RFC 8259, strict).
--
-- The whole input must be well-formed UTF-8 without a byte-order mark, and
-- consist of exactly one value surrounded by optional JSON whitespace (space,
-- tab, LF, CR). All of the input is checked, including values that a later
-- duplicate key would override.
parse :: ByteString -> Either ParseError Value
parse bs = case validateUtf8 bs of
  Just off -> Left (ParseError off "invalid UTF-8")
  Nothing -> case value bs 0 0 of
    Bad e -> Left e
    Good i v
      | j == BS.length bs -> Right v
      | otherwise -> Left (ParseError j "unexpected data after the value")
      where
        j = skipWs bs i

-- | Result of a parsing step: an error, or the position after the parsed
-- item together with the item.
data R a = Bad !ParseError | Good !Int !a

bad :: Int -> String -> R a
bad i msg = Bad (ParseError i msg)

-- | Byte at a position, or -1 past the end.
peek :: ByteString -> Int -> Int
peek bs i
  | i < BS.length bs = fromIntegral (BU.unsafeIndex bs i)
  | otherwise = -1
{-# INLINE peek #-}

skipWs :: ByteString -> Int -> Int
skipWs bs = go
  where
    go !i = case peek bs i of
      0x20 -> go (i + 1)
      0x09 -> go (i + 1)
      0x0A -> go (i + 1)
      0x0D -> go (i + 1)
      _ -> i

isDigit :: Int -> Bool
isDigit c = c >= 0x30 && c <= 0x39

skipDigits :: ByteString -> Int -> Int
skipDigits bs = go
  where
    go !i = if isDigit (peek bs i) then go (i + 1) else i

slice :: ByteString -> Int -> Int -> ByteString
slice bs s e = BU.unsafeTake (e - s) (BU.unsafeDrop s bs)

-- | Parse a value (leading whitespace allowed). The first argument after the
-- input is the depth of the enclosing container (0 at top level).
value :: ByteString -> Int -> Int -> R Value
value bs !dep i0
  | i >= BS.length bs = bad i "unexpected end of input"
  | otherwise = case peek bs i of
      0x7B -> if dep >= maxDepth then tooDeep else object bs (dep + 1) (i + 1)
      0x5B -> if dep >= maxDepth then tooDeep else array bs (dep + 1) (i + 1)
      0x22 -> case string bs i of
        Bad e -> Bad e
        Good j t -> Good j (String t)
      0x74 -> literal "true" (Bool True)
      0x66 -> literal "false" (Bool False)
      0x6E -> literal "null" Null
      c | c == 0x2D || isDigit c -> number bs i
        | otherwise -> bad i "unexpected character"
  where
    i = skipWs bs i0
    tooDeep = bad i "nesting too deep"
    literal lit v
      | lit `BS.isPrefixOf` BU.unsafeDrop i bs = Good (i + BS.length lit) v
      | otherwise = bad i "invalid literal"

-- | After the opening bracket; the argument is this array's own depth.
array :: ByteString -> Int -> Int -> R Value
array bs !dep i0
  | peek bs i == 0x5D = Good (i + 1) (Array [])
  | otherwise = elems i []
  where
    i = skipWs bs i0
    elems !j acc = case value bs dep j of
      Bad e -> Bad e
      Good k v ->
        let k' = skipWs bs k
            acc' = v : acc
         in case peek bs k' of
              0x2C -> elems (k' + 1) acc'
              0x5D -> Good (k' + 1) (Array (reverse acc'))
              _ -> bad k' "expected ',' or ']'"

-- | After the opening brace; the argument is this object's own depth.
object :: ByteString -> Int -> Int -> R Value
object bs !dep i0
  | peek bs i == 0x7D = Good (i + 1) (Object [])
  | otherwise = members i []
  where
    i = skipWs bs i0
    members !j0 acc
      | peek bs j /= 0x22 = bad j "expected string key"
      | otherwise = case string bs j of
          Bad e -> Bad e
          Good k1 key
            | peek bs k2 /= 0x3A -> bad k2 "expected ':'"
            | otherwise -> case value bs dep (k2 + 1) of
                Bad e -> Bad e
                Good k3 v ->
                  let k4 = skipWs bs k3
                      acc' = (key, v) : acc
                   in case peek bs k4 of
                        0x2C -> members (k4 + 1) acc'
                        0x7D -> Good (k4 + 1) (Object (reverse acc'))
                        _ -> bad k4 "expected ',' or '}'"
            where
              k2 = skipWs bs k1
      where
        j = skipWs bs j0

-- | Parse a string; the position is that of the opening quote. Input is known
-- to be valid UTF-8, so unescaped runs are copied through verbatim.
string :: ByteString -> Int -> R Text
string bs i0 = go s0 s0 []
  where
    !n = BS.length bs
    !s0 = i0 + 1
    -- start: beginning of the pending raw run; j: scan position;
    -- chunks: finished pieces, most recent first.
    go !start !j chunks
      | j >= n = bad n "unterminated string"
      | b == 0x22 = Good (j + 1) (decode (finish start j chunks))
      | b == 0x5C = escape start j chunks
      | b < 0x20 = bad j "control character in string"
      | otherwise = go start (j + 1) chunks
      where
        b = BU.unsafeIndex bs j
    finish start j [] = slice bs start j
    finish start j chunks = BS.concat (reverse (slice bs start j : chunks))
    decode = TE.decodeUtf8
    escape start j chunks = case peek bs (j + 1) of
      0x22 -> simple 0x22
      0x5C -> simple 0x5C
      0x2F -> simple 0x2F
      0x62 -> simple 0x08
      0x66 -> simple 0x0C
      0x6E -> simple 0x0A
      0x72 -> simple 0x0D
      0x74 -> simple 0x09
      0x75 -> unicode
      _ -> bad (j + 1) "invalid escape"
      where
        resume end piece = go end end (piece : slice bs start j : chunks)
        simple w = resume (j + 2) (BS.singleton w)
        unicode
          | u < 0 = bad (j + 2) "invalid \\u escape"
          | u >= 0xD800 && u <= 0xDBFF =
              if peek bs (j + 6) == 0x5C && peek bs (j + 7) == 0x75
                then
                  let l = hex4 bs (j + 8)
                   in if l >= 0xDC00 && l <= 0xDFFF
                        then resume (j + 12) (encode (0x10000 + ((u - 0xD800) `shiftL` 10) + (l - 0xDC00)))
                        else bad (j + 6) "high surrogate not followed by a low surrogate"
                else bad (j + 6) "high surrogate not followed by a low surrogate"
          | u >= 0xDC00 && u <= 0xDFFF = bad j "unpaired low surrogate"
          | otherwise = resume (j + 6) (encode u)
          where
            u = hex4 bs (j + 2)

-- | Value of four hex digits at a position, or -1.
hex4 :: ByteString -> Int -> Int
hex4 bs i = go 0 0
  where
    go :: Int -> Int -> Int
    go !k !acc
      | k == 4 = acc
      | d < 0 = -1
      | otherwise = go (k + 1) (acc * 16 + d)
      where
        c = peek bs (i + k)
        d | c >= 0x30 && c <= 0x39 = c - 0x30
          | c >= 0x41 && c <= 0x46 = c - 0x41 + 10
          | c >= 0x61 && c <= 0x66 = c - 0x61 + 10
          | otherwise = -1

-- | UTF-8 encoding of a scalar value.
encode :: Int -> ByteString
encode c
  | c < 0x80 = BS.pack [w c]
  | c < 0x800 = BS.pack [w (0xC0 .|. c `shiftR` 6), cont c]
  | c < 0x10000 = BS.pack [w (0xE0 .|. c `shiftR` 12), cont (c `shiftR` 6), cont c]
  | otherwise = BS.pack [w (0xF0 .|. c `shiftR` 18), cont (c `shiftR` 12), cont (c `shiftR` 6), cont c]
  where
    w :: Int -> Word8
    w = fromIntegral
    cont x = w (0x80 .|. x .&. 0x3F)

-- | Parse a number at a position holding @-@ or a digit, producing its
-- canonical text.
number :: ByteString -> Int -> R Value
number bs i0 = case peek bs s1 of
  0x30 -> afterInt (s1 + 1)
  c | c >= 0x31 && c <= 0x39 -> afterInt (skipDigits bs (s1 + 1))
    | otherwise -> bad s1 "expected digit"
  where
    s1 = if peek bs i0 == 0x2D then i0 + 1 else i0
    afterInt p
      | peek bs p == 0x2E =
          let q = skipDigits bs (p + 1)
           in if q == p + 1 then bad (p + 1) "expected digit after '.'" else afterFrac q
      | otherwise = afterFrac p
    afterFrac p
      | c == 0x65 || c == 0x45 =
          let sgn = peek bs (p + 1)
              ds = if sgn == 0x2B || sgn == 0x2D then p + 2 else p + 1
              q = skipDigits bs ds
              stripped = BS.dropWhile (== 0x30) (slice bs ds q)
              expo
                | BS.null stripped = "0"
                | sgn == 0x2D = BS.cons 0x2D stripped
                | otherwise = stripped
           in if q == ds
                then bad ds "expected digit in exponent"
                else Good q (Number (TE.decodeUtf8 (BS.concat [slice bs i0 p, "e", expo])))
      | otherwise = Good p (Number (TE.decodeUtf8 (slice bs i0 p)))
      where
        c = peek bs p

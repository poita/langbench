-- | Character-set decoding (ASCII, UTF-8, Latin-1, cp1252) and UTF-8
-- encoding.  The UTF-8 decoder follows the Unicode "maximal subpart"
-- replacement rule.
module Mime.Charset
  ( decode
  , decodeUtf8
  , encodeUtf8
  , normalizeCharset
  ) where

import Data.Bits (shiftL, (.&.), (.|.), shiftR)
import qualified Data.ByteString as B
import Data.Char (chr, ord)
import Data.Word (Word8)

import Mime.Lexical (lowerAscii, stripBlanks)

-- | Normalise a charset name: strip blanks, lower-case ASCII letters.
normalizeCharset :: String -> String
normalizeCharset = lowerAscii . stripBlanks

-- | @decode bytes charset@ decodes bytes using the named charset.  Unknown
-- and empty names decode as cp1252.
decode :: String -> B.ByteString -> String
decode name bs = case normalizeCharset name of
  n | n `elem` ["us-ascii", "ascii", "iso-ir-6", "ansi_x3.4-1968", "iso646-us"] ->
        map (\w -> if w < 0x80 then chr (fromIntegral w) else '\xFFFD') (B.unpack bs)
    | n `elem` ["utf-8", "utf8", "unicode-1-1-utf-8"] -> decodeUtf8 bs
    | n `elem` ["iso-8859-1", "iso8859-1", "latin-1", "latin1", "l1", "8859-1", "iso_8859-1"] ->
        map (chr . fromIntegral) (B.unpack bs)
    | otherwise -> map cp1252 (B.unpack bs)

cp1252 :: Word8 -> Char
cp1252 w
  | w >= 0x80 && w <= 0x9F = table !! fromIntegral (w - 0x80)
  | otherwise = chr (fromIntegral w)
  where
    table =
      map chr
        [ 0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021
        , 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F
        , 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014
        , 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178
        ]

-- | Decode UTF-8, replacing invalid input by U+FFFD using the maximal
-- subpart rule.
decodeUtf8 :: B.ByteString -> String
decodeUtf8 bs = go 0
  where
    n = B.length bs
    at i = fromIntegral (B.index bs i) :: Int
    go i
      | i >= n = []
      | b0 < 0x80 = chr b0 : go (i + 1)
      | otherwise = case lead b0 of
          Nothing -> '\xFFFD' : go (i + 1)
          Just (len, lo, hi) -> cont i len lo hi (b0 .&. mask len) 1
      where
        b0 = at i
    mask :: Int -> Int
    mask 2 = 0x1F
    mask 3 = 0x0F
    mask _ = 0x07
    cont i len lo hi acc k
      | k == len = chr acc : go (i + len)
      | i + k >= n = '\xFFFD' : go (i + k)
      | b >= l && b <= h = cont i len lo hi ((acc `shiftL` 6) .|. (b .&. 0x3F)) (k + 1)
      | otherwise = '\xFFFD' : go (i + k)
      where
        b = at (i + k)
        (l, h) = if k == 1 then (lo, hi) else (0x80, 0xBF)
    lead :: Int -> Maybe (Int, Int, Int)
    lead b
      | b >= 0xC2 && b <= 0xDF = Just (2, 0x80, 0xBF)
      | b == 0xE0 = Just (3, 0xA0, 0xBF)
      | b >= 0xE1 && b <= 0xEC = Just (3, 0x80, 0xBF)
      | b == 0xED = Just (3, 0x80, 0x9F)
      | b >= 0xEE && b <= 0xEF = Just (3, 0x80, 0xBF)
      | b == 0xF0 = Just (4, 0x90, 0xBF)
      | b >= 0xF1 && b <= 0xF3 = Just (4, 0x80, 0xBF)
      | b == 0xF4 = Just (4, 0x80, 0x8F)
      | otherwise = Nothing

-- | Encode a string as UTF-8.
encodeUtf8 :: String -> B.ByteString
encodeUtf8 = B.pack . concatMap enc
  where
    enc c
      | o < 0x80 = [fromIntegral o]
      | o < 0x800 = [0xC0 .|. hi 6, cont 0]
      | o < 0x10000 = [0xE0 .|. hi 12, cont 6, cont 0]
      | otherwise = [0xF0 .|. hi 18, cont 12, cont 6, cont 0]
      where
        o = ord c
        hi s = fromIntegral (o `shiftR` s)
        cont s = 0x80 .|. fromIntegral ((o `shiftR` s) .&. 0x3F)

{-# LANGUAGE OverloadedStrings #-}

-- | Character-level helpers shared by the block and inline parsers and the
-- HTML renderer: entity decoding, backslash escapes, HTML and URL escaping.
module Sitegen.Markdown.Escape
  ( isAsciiPunct
  , isMdSpace
  , matchEntity
  , decodeEntities
  , unescapeBackslashes
  , cleanDestination
  , escapeHtml
  , escapeHref
  ) where

import Data.Bits (shiftR, (.&.))
import Data.Char (chr, isDigit, isHexDigit, digitToInt)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as B

-- | ASCII punctuation, the set that backslash escapes apply to.
isAsciiPunct :: Char -> Bool
isAsciiPunct c =
  (c >= '!' && c <= '/') || (c >= ':' && c <= '@')
    || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')

-- | The whitespace set of the converter: space, tab, LF, VT, FF, CR.
isMdSpace :: Char -> Bool
isMdSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'

-- | Try to match an entity reference whose text starts right after the @&@.
-- Returns the decoded text and the number of characters consumed after the
-- @&@ (including the @;@).
matchEntity :: Text -> Maybe (Text, Int)
matchEntity r = case T.uncons r of
  Just ('#', r1) -> case T.uncons r1 of
    Just (x, r2)
      | x == 'x' || x == 'X' ->
          numeric (T.takeWhile isHexDigit r2) 16 6 2 r2
    _ -> numeric (T.takeWhile isDigit r1) 10 7 1 r1
  _ -> named
  where
    numeric digits base maxLen prefixLen rest
      | n >= 1 && n <= maxLen && T.isPrefixOf ";" (T.drop n rest) =
          Just (T.singleton (codePoint value), prefixLen + n + 1)
      | otherwise = Nothing
      where
        n = T.length digits
        value = T.foldl' (\a d -> a * base + digitToInt d) 0 digits
    named = case filter (\(k, _) -> T.isPrefixOf k r) table of
      ((k, v) : _) -> Just (v, T.length k)
      [] -> Nothing
    table = [("amp;", "&"), ("lt;", "<"), ("gt;", ">"), ("quot;", "\"")]
    codePoint v
      | v == 0 || (v >= 0xD800 && v < 0xE000) || v > 0x10FFFF = '\xFFFD'
      | otherwise = chr v

-- | Replace every entity reference in the text by the character it denotes.
decodeEntities :: Text -> Text
decodeEntities t
  | not (T.any (== '&') t) = t
  | otherwise = go t
  where
    go s = case T.break (== '&') s of
      (a, rest)
        | T.null rest -> a
        | otherwise ->
            let r = T.drop 1 rest
             in case matchEntity (T.take 10 r) of
                  Just (txt, n) -> T.concat [a, txt, go (T.drop n r)]
                  Nothing -> T.concat [a, "&", go r]

-- | Remove the backslash of every backslash escape.
unescapeBackslashes :: Text -> Text
unescapeBackslashes t
  | not (T.any (== '\\') t) = t
  | otherwise = go t
  where
    go s = case T.break (== '\\') s of
      (a, rest) -> case T.uncons rest of
        Nothing -> a
        Just (_, r) -> case T.uncons r of
          Just (c, r') | isAsciiPunct c -> T.concat [a, T.singleton c, go r']
          _ -> T.concat [a, "\\", go r]

-- | Process a raw link destination or title: entities, then backslashes.
cleanDestination :: Text -> Text
cleanDestination = unescapeBackslashes . decodeEntities

-- | Escape @& < > "@ for HTML text and attribute values.
escapeHtml :: Text -> Text
escapeHtml t
  | not (T.any needs t) = t
  | otherwise = T.concatMap esc t
  where
    needs c = c == '&' || c == '<' || c == '>' || c == '"'
    esc '&' = "&amp;"
    esc '<' = "&lt;"
    esc '>' = "&gt;"
    esc '"' = "&quot;"
    esc c = T.singleton c

-- | Encode a URL for an @href@ or @src@ attribute. Unsafe schemes yield the
-- empty string.
escapeHref :: Text -> Text
escapeHref url
  | dangerous = ""
  | otherwise = T.concatMap enc url
  where
    lower = T.toLower (T.take 16 url)
    dangerous =
      any (`T.isPrefixOf` lower) ["javascript:", "vbscript:", "file:", "data:"]
        && not (any (`T.isPrefixOf` lower)
                  ["data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"])
    enc c
      | safe c = T.singleton c
      | c == '&' = "&amp;"
      | c == '\'' = "&#x27;"
      | otherwise = T.concat (map pct (B.unpack (TE.encodeUtf8 (T.singleton c))))
    safe c =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c `elem` ("-_.~!#$%()*+,/:;=?@" :: String)
    pct b = T.pack ['%', hex (b `shiftR` 4), hex (b .&. 15)]
    hex n = "0123456789ABCDEF" !! fromIntegral n

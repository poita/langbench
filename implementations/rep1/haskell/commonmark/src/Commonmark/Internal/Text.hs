{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Commonmark.Internal.Text
-- Description : Byte-level character classes and entity / escape decoding.
--
-- Internal helpers shared by the block, inline and rendering modules.  The
-- converter works on UTF-8 bytes directly: all CommonMark syntax is ASCII,
-- and every non-ASCII byte is treated as an ordinary, letter-like character.
module Commonmark.Internal.Text
  ( -- * Character classes
    isSpaceW
  , isSpaceOrTab
  , isPunctW
  , isDigitW
  , isHexW
  , isAlphaW
  , isAlnumW
  , peekAt
    -- * Entities and escapes
  , matchEntity
  , decodeEntities
  , unescapeBackslashes
  , codePointToUtf8
    -- * Trimming
  , trimWs
  ) where

import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)

-- | The @cmark_isspace@ set: space, TAB, LF, VT, FF, CR.
isSpaceW :: Word8 -> Bool
isSpaceW w = w == 32 || (w >= 9 && w <= 13)
{-# INLINE isSpaceW #-}

-- | Exactly space or TAB.
isSpaceOrTab :: Word8 -> Bool
isSpaceOrTab w = w == 32 || w == 9
{-# INLINE isSpaceOrTab #-}

-- | ASCII punctuation.
isPunctW :: Word8 -> Bool
isPunctW w =
  (w >= 33 && w <= 47) || (w >= 58 && w <= 64) || (w >= 91 && w <= 96) || (w >= 123 && w <= 126)
{-# INLINE isPunctW #-}

isDigitW :: Word8 -> Bool
isDigitW w = w >= 48 && w <= 57
{-# INLINE isDigitW #-}

isHexW :: Word8 -> Bool
isHexW w = isDigitW w || (w >= 65 && w <= 70) || (w >= 97 && w <= 102)
{-# INLINE isHexW #-}

isAlphaW :: Word8 -> Bool
isAlphaW w = (w >= 65 && w <= 90) || (w >= 97 && w <= 122)
{-# INLINE isAlphaW #-}

isAlnumW :: Word8 -> Bool
isAlnumW w = isAlphaW w || isDigitW w
{-# INLINE isAlnumW #-}

-- | The byte at an index, or LF (10) when the index is past the end (every
-- line is treated as if terminated by a newline).
peekAt :: ByteString -> Int -> Word8
peekAt s i
  | i >= 0 && i < B.length s = BU.unsafeIndex s i
  | otherwise = 10
{-# INLINE peekAt #-}

-- | Encode a code point as UTF-8.  0, surrogates and values above U+10FFFF
-- become U+FFFD.
codePointToUtf8 :: Int -> ByteString
codePointToUtf8 c0
  | c < 0x80 = B.singleton (fromIntegral c)
  | c < 0x800 = B.pack [0xC0 .|. hi 6, cont 0]
  | c < 0x10000 = B.pack [0xE0 .|. hi 12, cont 6, cont 0]
  | otherwise = B.pack [0xF0 .|. hi 18, cont 12, cont 6, cont 0]
  where
    c
      | c0 == 0 || c0 > 0x10FFFF || (c0 >= 0xD800 && c0 <= 0xDFFF) = 0xFFFD
      | otherwise = c0
    hi n = fromIntegral (c `shiftR` n)
    cont n = 0x80 .|. (fromIntegral (c `shiftR` n) .&. 0x3F)

-- | @matchEntity s i@ tries to match an entity reference whose @&@ is at
-- index @i - 1@, i.e. @i@ is the index right after the ampersand.  On
-- success it returns the decoded UTF-8 text and the index after the @;@.
--
-- Recognised: decimal (1–7 digits) and hexadecimal (1–6 digits) numeric
-- references and the named references @amp@, @lt@, @gt@ and @quot@.
matchEntity :: ByteString -> Int -> Maybe (ByteString, Int)
matchEntity s i
  | peekAt s i == 35 =
      if peekAt s (i + 1) == 120 || peekAt s (i + 1) == 88
        then numeric 16 isHexW 6 (i + 2)
        else numeric 10 isDigitW 7 (i + 1)
  | otherwise = named
  where
    n = B.length s
    numeric :: Int -> (Word8 -> Bool) -> Int -> Int -> Maybe (ByteString, Int)
    numeric base isD maxDigits start =
      let digits = B.takeWhile isD (B.take maxDigits (B.drop start s))
          k = B.length digits
          end = start + k
       in if k >= 1 && end < n && BU.unsafeIndex s end == 59
            then Just (codePointToUtf8 (B.foldl' (\a d -> a * base + digitVal d) 0 digits), end + 1)
            else Nothing
    digitVal d
      | d <= 57 = fromIntegral d - 48
      | d >= 97 = fromIntegral d - 87
      | otherwise = fromIntegral d - 55
    rest = B.drop i s
    named
      | "amp;" `B.isPrefixOf` rest = Just ("&", i + 4)
      | "lt;" `B.isPrefixOf` rest = Just ("<", i + 3)
      | "gt;" `B.isPrefixOf` rest = Just (">", i + 3)
      | "quot;" `B.isPrefixOf` rest = Just ("\"", i + 5)
      | otherwise = Nothing

-- | Decode all entity references in a string.
decodeEntities :: ByteString -> ByteString
decodeEntities s
  | B.notElem 38 s = s
  | otherwise = B.concat (go s 0)
  where
    go str from =
      case B.elemIndex 38 (B.drop from str) of
        Nothing -> [B.drop from str]
        Just rel ->
          let amp = from + rel
           in case matchEntity str (amp + 1) of
                Just (txt, after) -> B.take rel (B.drop from str) : txt : go str after
                Nothing -> B.take (rel + 1) (B.drop from str) : go str (amp + 1)

-- | Remove backslash escapes: a backslash before an ASCII punctuation
-- character is deleted.
unescapeBackslashes :: ByteString -> ByteString
unescapeBackslashes s
  | B.notElem 92 s = s
  | otherwise = B.concat (go s)
  where
    go str =
      case B.elemIndex 92 str of
        Nothing -> [str]
        Just k
          | k + 1 < B.length str && isPunctW (BU.unsafeIndex str (k + 1)) ->
              B.take k str : B.take 1 (B.drop (k + 1) str) : go (B.drop (k + 2) str)
          | otherwise -> B.take (k + 1) str : go (B.drop (k + 1) str)

-- | Trim 'isSpaceW' characters from both ends.
trimWs :: ByteString -> ByteString
trimWs = B.dropWhileEnd isSpaceW . B.dropWhile isSpaceW

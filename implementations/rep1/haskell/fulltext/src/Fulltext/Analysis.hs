{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Fulltext.Analysis
-- Description : Tokenising, case folding, stop words and stemming.
--
-- Documents and queries are analysed by the same three steps: tokenise,
-- fold, stem.  Case folding is deliberately ASCII-only.
module Fulltext.Analysis
  ( -- * Tokens
    Token (..)
  , tokenize
  , isTokenChar
  , isApostrophe
  , isSpaceChar
    -- * Folding, stop words and terms
  , foldToken
  , stopWords
  , isStopWord
  , termOf
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Fulltext.Porter (stem)

-- | A token of a text.
data Token = Token
  { tokStart :: !Int  -- ^ offset (in code points) of the first character
  , tokEnd   :: !Int  -- ^ offset one past the last character
  , tokText  :: Text  -- ^ the folded token text (apostrophes removed, @A–Z@ lower-cased)
  } deriving (Eq, Show)

-- | Is the character part of a token?  ASCII digits and letters, the Latin
-- letters U+00C0–U+024F (except U+00D7 and U+00F7), Greek and Cyrillic.
isTokenChar :: Char -> Bool
isTokenChar c =
     (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
  || (c >= '\xC0' && c <= '\x24F' && c /= '\xD7' && c /= '\xF7')
  || (c >= '\x370' && c <= '\x4FF')

-- | U+0027 and U+2019.
isApostrophe :: Char -> Bool
isApostrophe c = c == '\'' || c == '\x2019'

-- | The seven whitespace characters of the specification: tab, LF, VT, FF,
-- CR, space and no-break space.
isSpaceChar :: Char -> Bool
isSpaceChar c = c == ' ' || (c >= '\t' && c <= '\r') || c == '\xA0'

-- | Fold one character: delete nothing, map @A–Z@ to @a–z@.
foldChar :: Char -> Char
foldChar c | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
           | otherwise = c

-- | Fold a raw token: delete apostrophes, lower-case ASCII letters.
foldToken :: Text -> Text
foldToken = T.map foldChar . T.filter (not . isApostrophe)

-- | Split a text into tokens: a maximal run of token characters, optionally
-- continued by apostrophes that sit between token characters.
tokenize :: Text -> [Token]
tokenize = go 0 . T.unpack
  where
    go :: Int -> String -> [Token]
    go !_ [] = []
    go !i s@(c : cs)
      | isTokenChar c = scan i i [] s
      | otherwise = go (i + 1) cs

    -- scan start position acc rest: @acc@ holds the folded characters so far
    -- (reversed) and @rest@ starts at offset @pos@.
    scan :: Int -> Int -> String -> String -> [Token]
    scan !start !pos acc s = case s of
      (c : r)
        | isTokenChar c -> scan start (pos + 1) (foldChar c : acc) r
        | isApostrophe c, (d : _) <- r, isTokenChar d -> scan start (pos + 1) acc r
      _ -> Token start pos (T.pack (reverse acc)) : go pos s

-- | The 33 stop words.
stopWords :: Set Text
stopWords = Set.fromList $ T.words
  "a an and are as at be but by for if in into is it no not of on or such \
  \that the their then there these they this to was will with"

-- | Is this /folded/ token text a stop word?
isStopWord :: Text -> Bool
isStopWord = (`Set.member` stopWords)

-- | The index term of a /folded/ token text: its Porter stem when it
-- consists only of the letters @a–z@, otherwise the text itself.
termOf :: Text -> Text
termOf t
  | T.all (\c -> c >= 'a' && c <= 'z') t = T.pack (stem (T.unpack t))
  | otherwise = t

-- | Small lexical helpers shared by the header-value parsers.
module Mime.Lexical
  ( isBlank
  , stripBlanks
  , collapse
  , lowerAscii
  , lowerStr
  , quotedString
  , skipComment
  , isHex
  , hexVal
  ) where

import Data.Char (chr, isAsciiUpper, ord, toLower)
import Data.List (dropWhileEnd)

-- | SPACE or TAB.
isBlank :: Char -> Bool
isBlank c = c == ' ' || c == '\t'

-- | Strip leading and trailing spaces and tabs.
stripBlanks :: String -> String
stripBlanks = dropWhileEnd isBlank . dropWhile isBlank

-- | Replace each maximal run of blanks by one space, then strip a leading and
-- trailing space.
collapse :: String -> String
collapse s = case words' s of
  [] -> ""
  ws -> foldr1 (\a b -> a ++ ' ' : b) ws
  where
    words' str = case dropWhile isBlank str of
      "" -> []
      str' -> let (w, r) = break isBlank str' in w : words' r

-- | Lower-case ASCII letters only.
lowerAscii :: String -> String
lowerAscii = map (\c -> if isAsciiUpper c then chr (ord c + 32) else c)

-- | General lower-casing (used for header, parameter and type names).
lowerStr :: String -> String
lowerStr = map toLower

-- | Scan a quoted string whose opening quote has been consumed.  Returns the
-- unescaped contents, the number of characters consumed (including the closing
-- quote, if any) and the remaining input.  An unterminated string runs to the
-- end of the input; a trailing lone backslash stands for itself.
quotedString :: String -> (String, Int, String)
quotedString = go 0
  where
    go !n s = case s of
      [] -> ([], n, [])
      '"' : r -> ([], n + 1, r)
      '\\' : c : r -> let (t, m, r') = go (n + 2) r in (c : t, m, r')
      c : r -> let (t, m, r') = go (n + 1) r in (c : t, m, r')

-- | Skip a comment whose opening parenthesis has been consumed.  Handles
-- nesting and backslash escapes; returns the number of characters consumed and
-- the remaining input.
skipComment :: String -> (Int, String)
skipComment = go (1 :: Int) 0
  where
    go _ !n [] = (n, [])
    go d !n (c : r) = case c of
      '\\' -> case r of
        [] -> (n + 1, [])
        _ : r' -> go d (n + 2) r'
      '(' -> go (d + 1) (n + 1) r
      ')' -> if d == 1 then (n + 1, r) else go (d - 1) (n + 1) r
      _ -> go d (n + 1) r

-- | ASCII hexadecimal digit.
isHex :: Char -> Bool
isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

-- | Value of an ASCII hexadecimal digit (undefined result for others).
hexVal :: Char -> Int
hexVal c
  | c >= '0' && c <= '9' = ord c - 48
  | c >= 'a' && c <= 'f' = ord c - 87
  | otherwise = ord c - 55

-- |
-- Module      : Chip8.Input
-- Description : Parser for the textual program input format.
--
-- The format is three lines: the ROM as lowercase hex, the cycle count in
-- decimal, and an optional key schedule of @cycle:mask@ events separated by
-- spaces, where @mask@ is four hex digits.
module Chip8.Input
  ( Input (..)
  , parseInput
  ) where

import Data.Char (digitToInt, isDigit, isHexDigit)
import Data.Word (Word8)

import Chip8.Types

-- | A parsed program input.
data Input = Input
  { inputRom    :: Rom
  , inputCycles :: !Int
  , inputKeys   :: [KeyEvent]
  } deriving (Eq, Show)

-- | Parse the whole input text.  Returns an error message on malformed input.
parseInput :: String -> Either String Input
parseInput txt = case map stripCR (lines txt) of
  (romLine : cycLine : rest) -> do
    rom <- parseRom romLine
    cycles <- parseDecimal "cycle count" cycLine
    keys <- case rest of
      []      -> Right []
      (k : _) -> parseSchedule k
    Right (Input rom cycles keys)
  _ -> Left "expected a ROM line and a cycle-count line"
  where
    stripCR = filter (/= '\r')

parseRom :: String -> Either String Rom
parseRom s
  | null s = Left "empty ROM"
  | not (all isHexDigit s) = Left "ROM contains a non-hex character"
  | odd (length s) = Left "ROM has an odd number of hex digits"
  | otherwise = Right (go s)
  where
    go (a : b : r) = fromIntegral (digitToInt a * 16 + digitToInt b) : go r
    go _ = [] :: [Word8]

parseDecimal :: String -> String -> Either String Int
parseDecimal what s
  | null s || not (all isDigit s) = Left ("invalid " ++ what ++ ": " ++ show s)
  | otherwise = Right (read s)

parseSchedule :: String -> Either String [KeyEvent]
parseSchedule = mapM event . words
  where
    event w = case break (== ':') w of
      (c, ':' : m)
        | length m == 4, all isHexDigit m ->
            KeyEvent <$> parseDecimal "key event cycle" c
                     <*> pure (foldl (\a d -> a * 16 + digitToInt d) 0 m)
      _ -> Left ("invalid key event: " ++ show w)

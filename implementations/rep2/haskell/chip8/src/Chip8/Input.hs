-- |
-- Module      : Chip8.Input
-- Description : Parsing of the textual problem input.
--
-- The input format is three lines: the ROM as lowercase hex, the cycle
-- budget in decimal, and an optional key schedule of @cycle:mask@ events.
module Chip8.Input
  ( Input (..)
  , KeyEvent (..)
  , parseInput
  ) where

import qualified Data.ByteString as B
import Data.Char (digitToInt, isDigit, isHexDigit)
import Data.Word (Word8)

-- | A key-state change: before cycle 'keyCycle' executes, the held keys
-- become 'keyMask' (bit @k@ = key @k@ down).
data KeyEvent = KeyEvent
  { keyCycle :: !Int
  , keyMask :: !Int
  }
  deriving (Eq, Show)

-- | A parsed program run request.
data Input = Input
  { inputRom :: !B.ByteString
  , inputCycles :: !Int
  , inputKeys :: [KeyEvent]
    -- ^ In strictly increasing order of cycle.
  }
  deriving (Eq, Show)

-- | Parse the full text of an input.  Returns a description of the problem
-- on malformed input.
parseInput :: String -> Either String Input
parseInput txt = case lines txt of
  (romLine : cyclesLine : rest) -> do
    rom <- parseRom romLine
    n <- parseDecimal "cycle count" cyclesLine
    events <- case rest of
      [] -> Right []
      (l : _) -> parseSchedule l
    checkOrder events
    Right (Input rom n events)
  _ -> Left "expected at least two lines (ROM and cycle count)"

parseRom :: String -> Either String B.ByteString
parseRom s
  | null s = Left "empty ROM"
  | odd (length s) = Left "ROM has an odd number of hex digits"
  | not (all isHexDigit s) = Left "ROM contains a non-hex character"
  | length s > 7168 = Left "ROM is longer than 3584 bytes"
  | otherwise = Right (B.pack (pairs s))
  where
    pairs :: String -> [Word8]
    pairs (a : b : r) = fromIntegral (digitToInt a * 16 + digitToInt b) : pairs r
    pairs _ = []

parseDecimal :: String -> String -> Either String Int
parseDecimal what s
  | null s || not (all isDigit s) = Left ("invalid " ++ what ++ ": " ++ show s)
  | otherwise = Right (read s)

parseSchedule :: String -> Either String [KeyEvent]
parseSchedule = mapM parseEvent . words

parseEvent :: String -> Either String KeyEvent
parseEvent w = case break (== ':') w of
  (c, ':' : m)
    | length m == 4 && all isHexDigit m -> do
        cyc <- parseDecimal "event cycle" c
        Right (KeyEvent cyc (foldl (\a d -> a * 16 + digitToInt d) 0 m))
  _ -> Left ("invalid key event: " ++ show w)

checkOrder :: [KeyEvent] -> Either String ()
checkOrder evs
  | and (zipWith (<) cs (drop 1 cs)) = Right ()
  | otherwise = Left "key events are not in strictly increasing cycle order"
  where
    cs = map keyCycle evs

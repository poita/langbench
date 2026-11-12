-- |
-- Module      : Chip8.Output
-- Description : Rendering a 'Snapshot' as the 34-line text report.
module Chip8.Output
  ( render
  , renderDisplay
  , renderStatus
  , renderRegisters
  ) where

import Data.Array.Unboxed (elems)
import Data.Word (Word8)
import Numeric (showHex)

import Chip8.Snapshot

-- | The full report: 32 display lines, the status line and the register
-- line, each terminated by a newline.
render :: Snapshot -> String
render s = unlines (renderDisplay s ++ [renderStatus s, renderRegisters s])

-- | The 32 display rows of 64 characters, @#@ lit and @.@ unlit.
renderDisplay :: Snapshot -> [String]
renderDisplay s = [[glyph (pixelAt s x y) | x <- [0 .. displayWidth - 1]] | y <- [0 .. displayHeight - 1]]
  where
    glyph True = '#'
    glyph False = '.'

-- | @PC=.... I=.... SP=n DT=.. ST=..@
renderStatus :: Snapshot -> String
renderStatus s =
  "PC=" ++ hex 4 (snapPC s)
    ++ " I=" ++ hex 4 (snapI s)
    ++ " SP=" ++ show (snapSP s)
    ++ " DT=" ++ hex 2 (fromIntegral (snapDT s))
    ++ " ST=" ++ hex 2 (fromIntegral (snapST s))

-- | @V=@ followed by the sixteen registers.
renderRegisters :: Snapshot -> String
renderRegisters s = "V=" ++ unwords (map hexByte (elems (snapV s)))
  where
    hexByte :: Word8 -> String
    hexByte = hex 2 . fromIntegral

-- | Lowercase hex, zero-padded to the given width.
hex :: Int -> Int -> String
hex w v = replicate (w - length d) '0' ++ d
  where
    d = showHex v ""

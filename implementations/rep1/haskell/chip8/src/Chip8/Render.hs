-- |
-- Module      : Chip8.Render
-- Description : Text rendering of a machine snapshot.
module Chip8.Render
  ( renderSnapshot
  , renderDisplay
  , renderStatus
  , renderRegisters
  ) where

import Data.Array.Unboxed (elems)
import Data.List (intercalate)
import Numeric (showHex)

import Chip8.Types

-- | The full 34-line report, each line newline-terminated.
renderSnapshot :: Snapshot -> String
renderSnapshot s = unlines (renderDisplay s ++ [renderStatus s, renderRegisters s])

-- | The 32 display rows of 64 characters, @#@ for lit and @.@ for unlit.
renderDisplay :: Snapshot -> [String]
renderDisplay s = [ [ if pixelAt s x y then '#' else '.' | x <- [0 .. displayWidth - 1] ]
                  | y <- [0 .. displayHeight - 1] ]

-- | The @PC=.. I=.. SP=.. DT=.. ST=..@ line.
renderStatus :: Snapshot -> String
renderStatus s = unwords
  [ "PC=" ++ hex 4 (snapPC s)
  , "I=" ++ hex 4 (snapI s)
  , "SP=" ++ show (snapSP s)
  , "DT=" ++ hex 2 (snapDT s)
  , "ST=" ++ hex 2 (snapST s)
  ]

-- | The @V=..@ line with the sixteen registers.
renderRegisters :: Snapshot -> String
renderRegisters s = "V=" ++ intercalate " " (map (hex 2) (elems (snapV s)))

hex :: (Integral a, Show a) => Int -> a -> String
hex w v = let h = showHex v "" in replicate (w - length h) '0' ++ h

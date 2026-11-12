-- |
-- Module      : Chip8
-- Description : A deterministic CHIP-8 interpreter.
--
-- This module re-exports the public API.  The usual entry points are:
--
-- * 'parseInput' to read the textual input format,
-- * 'runRom' / 'runInput' to execute a ROM for a number of cycles,
-- * 'render' to format the resulting 'Snapshot'.
--
-- For finer control, "Chip8.Machine" exposes the mutable machine and a
-- single-cycle 'step'.
--
-- > import Chip8
-- > import qualified Data.ByteString as B
-- >
-- > main :: IO ()
-- > main = putStr (render (runRom (B.pack [0x60, 0x2a]) 1 []))
module Chip8
  ( -- * Running
    runRom
  , runInput
    -- * Input
  , Input (..)
  , KeyEvent (..)
  , parseInput
    -- * Results
  , Snapshot (..)
  , pixelAt
  , displayWidth
  , displayHeight
  , render
    -- * Decoding
  , Instruction (..)
  , decode
  ) where

import Chip8.Input
import Chip8.Instruction
import Chip8.Output
import Chip8.Run
import Chip8.Snapshot

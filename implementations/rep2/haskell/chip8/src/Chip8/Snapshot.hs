-- |
-- Module      : Chip8.Snapshot
-- Description : Immutable view of a machine's observable state.
module Chip8.Snapshot
  ( Snapshot (..)
  , displayWidth
  , displayHeight
  , pixelAt
  ) where

import Data.Array.Unboxed (UArray, (!))
import Data.Word (Word8)

-- | Display width in pixels.
displayWidth :: Int
displayWidth = 64

-- | Display height in pixels.
displayHeight :: Int
displayHeight = 32

-- | The CPU state and display at one instant.
data Snapshot = Snapshot
  { snapPC :: !Int
    -- ^ Program counter (12 bits).
  , snapI :: !Int
    -- ^ Index register (16 bits).
  , snapSP :: !Int
    -- ^ Number of entries on the call stack (0..16).
  , snapDT :: !Word8
    -- ^ Delay timer.
  , snapST :: !Word8
    -- ^ Sound timer.
  , snapV :: !(UArray Int Word8)
    -- ^ Registers @V0@..@VF@, indexed 0..15.
  , snapDisplay :: !(UArray Int Bool)
    -- ^ Row-major display, index @y * 64 + x@, 'True' = lit.
  }
  deriving (Eq, Show)

-- | Is the pixel at column @x@ (0..63), row @y@ (0..31) lit?
pixelAt :: Snapshot -> Int -> Int -> Bool
pixelAt s x y = snapDisplay s ! (y * displayWidth + x)

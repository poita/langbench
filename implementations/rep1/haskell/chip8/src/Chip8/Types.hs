-- |
-- Module      : Chip8.Types
-- Description : Plain data types shared by the whole library.
module Chip8.Types
  ( Rom
  , KeyEvent (..)
  , Snapshot (..)
  , displayWidth
  , displayHeight
  , memorySize
  , programStart
  , pixelAt
  ) where

import Data.Array.Unboxed (UArray, (!))
import Data.Word (Word16, Word8)

-- | A program image: the bytes loaded into memory at 'programStart'.
type Rom = [Word8]

-- | A change of the held-key set.  The event takes effect immediately before
-- the cycle numbered 'keyCycle' executes.
data KeyEvent = KeyEvent
  { keyCycle :: !Int
    -- ^ 0-based cycle number at which the event applies.
  , keyMask  :: !Int
    -- ^ 16-bit key state; bit @k@ set means key @k@ is held down.
  } deriving (Eq, Show)

-- | An immutable view of the machine at some point in time.
data Snapshot = Snapshot
  { snapPC      :: !Word16
    -- ^ Program counter (12 bits).
  , snapI       :: !Word16
    -- ^ Index register (full 16 bits).
  , snapSP      :: !Int
    -- ^ Number of entries on the call stack (0-16).
  , snapDT      :: !Word8
    -- ^ Delay timer.
  , snapST      :: !Word8
    -- ^ Sound timer.
  , snapV       :: !(UArray Int Word8)
    -- ^ Registers @V0@..@VF@, indexed 0-15.
  , snapStack   :: !(UArray Int Word16)
    -- ^ The 16 stack slots.
  , snapMemory  :: !(UArray Int Word8)
    -- ^ The 4096 bytes of memory.
  , snapDisplay :: !(UArray Int Bool)
    -- ^ Row-major display, @y * 'displayWidth' + x@; 'True' means lit.
  } deriving (Eq, Show)

-- | Display width in pixels.
displayWidth :: Int
displayWidth = 64

-- | Display height in pixels.
displayHeight :: Int
displayHeight = 32

-- | Size of the address space in bytes.
memorySize :: Int
memorySize = 4096

-- | Address at which the ROM is loaded and execution starts.
programStart :: Int
programStart = 0x200

-- | Is the pixel at column @x@, row @y@ lit?
pixelAt :: Snapshot -> Int -> Int -> Bool
pixelAt s x y = snapDisplay s ! (y * displayWidth + x)

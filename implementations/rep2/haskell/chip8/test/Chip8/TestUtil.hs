-- | Helpers shared by the test modules.
module Chip8.TestUtil
  ( romOf
  , runOps
  , regs
  ) where

import Data.Array.Unboxed (elems)
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as B
import Data.Word (Word8)

import Chip8

-- | Assemble a list of 16-bit opcodes into a ROM.
romOf :: [Int] -> B.ByteString
romOf ops = B.pack (concat [[fromIntegral (o `shiftR` 8), fromIntegral (o .&. 0xFF)] | o <- ops])

-- | Run opcodes for @n@ cycles with no key events.
runOps :: [Int] -> Int -> Snapshot
runOps ops n = runRom (romOf ops) n []

-- | Register values @V0@..@VF@.
regs :: Snapshot -> [Word8]
regs = elems . snapV

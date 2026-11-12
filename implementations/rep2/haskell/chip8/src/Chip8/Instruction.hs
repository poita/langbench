-- |
-- Module      : Chip8.Instruction
-- Description : Opcode decoding.
--
-- 'decode' is a pure function from a 16-bit opcode to an 'Instruction'.  It
-- is total: every opcode that is not assigned a meaning decodes to 'Nop'.
module Chip8.Instruction
  ( Instruction (..)
  , Reg
  , decode
  ) where

import Data.Bits (shiftR, (.&.))

-- | A register index, 0..15.
type Reg = Int

-- | A decoded instruction.  Immediate operands are plain 'Int's:
-- @NN@ is 0..255 and @NNN@ is 0..4095.
data Instruction
  = Cls                    -- ^ @00E0@ clear the display
  | Ret                    -- ^ @00EE@ return from subroutine
  | Jp !Int                -- ^ @1NNN@
  | Call !Int              -- ^ @2NNN@
  | SeImm !Reg !Int        -- ^ @3XNN@ skip if @VX == NN@
  | SneImm !Reg !Int       -- ^ @4XNN@ skip if @VX /= NN@
  | SeReg !Reg !Reg        -- ^ @5XY0@ skip if @VX == VY@
  | LdImm !Reg !Int        -- ^ @6XNN@
  | AddImm !Reg !Int       -- ^ @7XNN@ (no flag)
  | LdReg !Reg !Reg        -- ^ @8XY0@
  | OrReg !Reg !Reg        -- ^ @8XY1@
  | AndReg !Reg !Reg       -- ^ @8XY2@
  | XorReg !Reg !Reg       -- ^ @8XY3@
  | AddReg !Reg !Reg       -- ^ @8XY4@ with carry in @VF@
  | SubReg !Reg !Reg       -- ^ @8XY5@ @VX = VX - VY@, @VF@ = no borrow
  | Shr !Reg               -- ^ @8XY6@ shift @VX@ right in place
  | SubnReg !Reg !Reg      -- ^ @8XY7@ @VX = VY - VX@, @VF@ = no borrow
  | Shl !Reg               -- ^ @8XYE@ shift @VX@ left in place
  | SneReg !Reg !Reg       -- ^ @9XY0@ skip if @VX /= VY@
  | LdI !Int               -- ^ @ANNN@
  | JpV0 !Int              -- ^ @BNNN@ jump to @NNN + V0@
  | Rnd !Reg !Int          -- ^ @CXNN@
  | Drw !Reg !Reg !Int     -- ^ @DXYN@
  | Skp !Reg               -- ^ @EX9E@ skip if key @VX@ is down
  | Sknp !Reg              -- ^ @EXA1@ skip if key @VX@ is up
  | LdVDt !Reg             -- ^ @FX07@ @VX = DT@
  | WaitKey !Reg           -- ^ @FX0A@
  | LdDtV !Reg             -- ^ @FX15@ @DT = VX@
  | LdStV !Reg             -- ^ @FX18@ @ST = VX@
  | AddI !Reg              -- ^ @FX1E@ @I += VX@
  | LdFont !Reg            -- ^ @FX29@ @I = font address of VX@
  | Bcd !Reg               -- ^ @FX33@
  | StoreRegs !Reg         -- ^ @FX55@
  | LoadRegs !Reg          -- ^ @FX65@
  | Nop                    -- ^ any opcode with no assigned meaning
  deriving (Eq, Show)

-- | Decode a 16-bit opcode (given as an 'Int' in @0..0xFFFF@).
decode :: Int -> Instruction
decode op = case op `shiftR` 12 of
  0x0 -> case op of
    0x00E0 -> Cls
    0x00EE -> Ret
    _      -> Nop
  0x1 -> Jp nnn
  0x2 -> Call nnn
  0x3 -> SeImm x nn
  0x4 -> SneImm x nn
  0x5 | n == 0 -> SeReg x y
  0x6 -> LdImm x nn
  0x7 -> AddImm x nn
  0x8 -> case n of
    0x0 -> LdReg x y
    0x1 -> OrReg x y
    0x2 -> AndReg x y
    0x3 -> XorReg x y
    0x4 -> AddReg x y
    0x5 -> SubReg x y
    0x6 -> Shr x
    0x7 -> SubnReg x y
    0xE -> Shl x
    _   -> Nop
  0x9 | n == 0 -> SneReg x y
  0xA -> LdI nnn
  0xB -> JpV0 nnn
  0xC -> Rnd x nn
  0xD -> Drw x y n
  0xE -> case nn of
    0x9E -> Skp x
    0xA1 -> Sknp x
    _    -> Nop
  0xF -> case nn of
    0x07 -> LdVDt x
    0x0A -> WaitKey x
    0x15 -> LdDtV x
    0x18 -> LdStV x
    0x1E -> AddI x
    0x29 -> LdFont x
    0x33 -> Bcd x
    0x55 -> StoreRegs x
    0x65 -> LoadRegs x
    _    -> Nop
  _ -> Nop
  where
    x   = (op `shiftR` 8) .&. 0xF
    y   = (op `shiftR` 4) .&. 0xF
    n   = op .&. 0xF
    nn  = op .&. 0xFF
    nnn = op .&. 0xFFF

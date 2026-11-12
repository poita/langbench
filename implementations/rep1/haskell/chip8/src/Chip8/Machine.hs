-- |
-- Module      : Chip8.Machine
-- Description : The mutable machine state, living in 'ST'.
--
-- All state is held in unboxed mutable arrays.  Every accessor masks its
-- index, so the unchecked array operations used here can never go out of
-- bounds.  Registers are addressed by their nibble (0-15).
module Chip8.Machine
  ( Machine
  , newMachine
  , freezeMachine
    -- * Memory
  , readMem
  , writeMem
    -- * Registers
  , readV
  , writeV
    -- * Scalars
  , getPC, setPC
  , getI, setI
  , getSP, setSP
  , getDT, setDT
  , getST, setST
  , getKeys, setKeys
    -- * Stack
  , push
  , pop
    -- * Display
  , clearDisplay
  , xorPixel
    -- * RNG
  , nextRandomByte
  ) where

import Control.Monad (forM_)
import Control.Monad.ST (ST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, freeze, newArray)
import Data.Bits (shiftR, (.&.))
import Data.Word (Word16, Word32, Word8)

import Chip8.Font (fontBase, fontData)
import Chip8.Types

-- | A running CHIP-8 machine.
data Machine s = Machine
  { mMem     :: !(STUArray s Int Word8)
  , mV       :: !(STUArray s Int Word8)
  , mStack   :: !(STUArray s Int Word16)
  , mDisplay :: !(STUArray s Int Bool)
  , mScalars :: !(STUArray s Int Int)
    -- ^ PC, I, SP, DT, ST, RNG and key state, see the @s*@ indices below.
  }

sPC, sI, sSP, sDT, sST, sRNG, sKeys, scalarCount :: Int
sPC = 0
sI = 1
sSP = 2
sDT = 3
sST = 4
sRNG = 5
sKeys = 6
scalarCount = 7

-- | Seed of the random number generator.
rngSeed :: Int
rngSeed = 0x12345678

-- | A fresh machine with the font and the given ROM loaded.  Bytes of the ROM
-- that do not fit in memory are ignored.
newMachine :: Rom -> ST s (Machine s)
newMachine rom = do
  mem <- newArray (0, memorySize - 1) 0
  v <- newArray (0, 15) 0
  st <- newArray (0, 15) 0
  disp <- newArray (0, displayWidth * displayHeight - 1) False
  sc <- newArray (0, scalarCount - 1) 0
  forM_ (zip [fontBase ..] fontData) $ uncurry (unsafeWrite mem)
  forM_ (zip [programStart .. memorySize - 1] rom) $ uncurry (unsafeWrite mem)
  unsafeWrite sc sPC programStart
  unsafeWrite sc sRNG rngSeed
  pure (Machine mem v st disp sc)

-- | Copy the machine's current state into an immutable 'Snapshot'.
freezeMachine :: Machine s -> ST s Snapshot
freezeMachine m = do
  pc <- getPC m
  i <- getI m
  sp <- getSP m
  dt <- getDT m
  st <- getST m
  mem <- freeze (mMem m)
  v <- freeze (mV m)
  stack <- freeze (mStack m)
  disp <- freeze (mDisplay m)
  pure Snapshot
    { snapPC = fromIntegral pc, snapI = fromIntegral i, snapSP = sp
    , snapDT = fromIntegral dt, snapST = fromIntegral st
    , snapV = v, snapStack = stack, snapMemory = mem, snapDisplay = disp }

-- | Read a byte; the address is masked to 12 bits.
readMem :: Machine s -> Int -> ST s Int
readMem m a = fromIntegral <$> unsafeRead (mMem m) (a .&. 0xFFF)
{-# INLINE readMem #-}

-- | Write a byte (truncated to 8 bits); the address is masked to 12 bits.
writeMem :: Machine s -> Int -> Int -> ST s ()
writeMem m a x = unsafeWrite (mMem m) (a .&. 0xFFF) (fromIntegral x)
{-# INLINE writeMem #-}

-- | Read register @Vn@ (the index is masked to 4 bits).
readV :: Machine s -> Int -> ST s Int
readV m r = fromIntegral <$> unsafeRead (mV m) (r .&. 15)
{-# INLINE readV #-}

-- | Write register @Vn@ (the value is truncated to 8 bits).
writeV :: Machine s -> Int -> Int -> ST s ()
writeV m r x = unsafeWrite (mV m) (r .&. 15) (fromIntegral x)
{-# INLINE writeV #-}

getPC, getI, getSP, getDT, getST, getKeys :: Machine s -> ST s Int
getPC m = unsafeRead (mScalars m) sPC
getI m = unsafeRead (mScalars m) sI
getSP m = unsafeRead (mScalars m) sSP
getDT m = unsafeRead (mScalars m) sDT
getST m = unsafeRead (mScalars m) sST
getKeys m = unsafeRead (mScalars m) sKeys
{-# INLINE getPC #-}
{-# INLINE getI #-}
{-# INLINE getSP #-}
{-# INLINE getDT #-}
{-# INLINE getST #-}
{-# INLINE getKeys #-}

-- | Set the program counter (masked to 12 bits).
setPC :: Machine s -> Int -> ST s ()
setPC m x = unsafeWrite (mScalars m) sPC (x .&. 0xFFF)
{-# INLINE setPC #-}

-- | Set the index register (masked to 16 bits).
setI :: Machine s -> Int -> ST s ()
setI m x = unsafeWrite (mScalars m) sI (x .&. 0xFFFF)
{-# INLINE setI #-}

-- | Set the stack pointer.
setSP :: Machine s -> Int -> ST s ()
setSP m = unsafeWrite (mScalars m) sSP
{-# INLINE setSP #-}

-- | Set the delay timer (masked to 8 bits).
setDT :: Machine s -> Int -> ST s ()
setDT m x = unsafeWrite (mScalars m) sDT (x .&. 0xFF)
{-# INLINE setDT #-}

-- | Set the sound timer (masked to 8 bits).
setST :: Machine s -> Int -> ST s ()
setST m x = unsafeWrite (mScalars m) sST (x .&. 0xFF)
{-# INLINE setST #-}

-- | Replace the held-key bitmask.
setKeys :: Machine s -> Int -> ST s ()
setKeys m x = unsafeWrite (mScalars m) sKeys (x .&. 0xFFFF)
{-# INLINE setKeys #-}

-- | Push a return address and increment @SP@.  Behaviour on a full stack is
-- unspecified (the slot index wraps).
push :: Machine s -> Int -> ST s ()
push m a = do
  sp <- getSP m
  unsafeWrite (mStack m) (sp .&. 15) (fromIntegral (a .&. 0xFFF))
  setSP m (sp + 1)

-- | Decrement @SP@ and return the entry it now points at.  Behaviour on an
-- empty stack is unspecified (the slot index wraps).
pop :: Machine s -> ST s Int
pop m = do
  sp <- subtract 1 <$> getSP m
  setSP m sp
  fromIntegral <$> unsafeRead (mStack m) (sp .&. 15)

-- | Turn every pixel off.
clearDisplay :: Machine s -> ST s ()
clearDisplay m =
  forM_ [0 .. displayWidth * displayHeight - 1] $ \k ->
    unsafeWrite (mDisplay m) k False

-- | XOR the pixel at (@x@, @y@), wrapping both coordinates.  Returns 'True'
-- if the pixel was lit before (that is, it has just been turned off).
xorPixel :: Machine s -> Int -> Int -> ST s Bool
xorPixel m x y = do
  let k = (y .&. 31) * displayWidth + (x .&. 63)
  old <- unsafeRead (mDisplay m) k
  unsafeWrite (mDisplay m) k (not old)
  pure old
{-# INLINE xorPixel #-}

-- | Advance the LCG once and return the new random byte.
nextRandomByte :: Machine s -> ST s Int
nextRandomByte m = do
  s <- unsafeRead (mScalars m) sRNG
  let s' = fromIntegral ((fromIntegral s * 1103515245 + 12345 :: Word32))
  unsafeWrite (mScalars m) sRNG s'
  pure ((s' `shiftR` 16) .&. 0xFF)

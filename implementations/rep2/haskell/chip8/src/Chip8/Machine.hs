{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Chip8.Machine
-- Description : The mutable CHIP-8 machine and its single-cycle step.
--
-- A 'Machine' lives in 'ST'.  Every call to 'step' performs exactly one
-- cycle: fetch from memory at @PC@, decode, execute, and tick the timers.
-- Nothing is cached or pre-decoded, so self-modifying programs behave
-- correctly.
--
-- Key-schedule events are applied by the caller (see "Chip8.Run") with
-- 'setKeys' before the cycle they take effect on.
module Chip8.Machine
  ( Machine
  , newMachine
  , step
  , setKeys
  , snapshot
  , romBase
  , memorySize
  , maxRomSize
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, getElems, newArray, newListArray)
import Data.Array.Unboxed (listArray)
import Data.Bits (countTrailingZeros, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.ByteString as B
import Data.Word (Word16, Word8)

import Chip8.Font (fontBase, fontBytes, glyphAddress)
import Chip8.Instruction
import Chip8.Snapshot

-- | Mutable machine state.
data Machine s = Machine
  { mMem     :: !(STUArray s Int Word8)   -- ^ 4096 bytes
  , mV       :: !(STUArray s Int Word8)   -- ^ 16 registers
  , mStack   :: !(STUArray s Int Word16)  -- ^ 16 return addresses
  , mDisplay :: !(STUArray s Int Word8)   -- ^ 64*32 pixels, 0 or 1
  , mScalars :: !(STUArray s Int Int)     -- ^ see the @r*@ indices below
  }

-- Indices into 'mScalars'.
rPC, rI, rSP, rDT, rST, rRng, rKeys, rCycles :: Int
rPC = 0
rI = 1
rSP = 2
rDT = 3
rST = 4
rRng = 5
rKeys = 6
rCycles = 7

-- | Total memory size in bytes.
memorySize :: Int
memorySize = 4096

-- | Address at which the ROM is loaded.
romBase :: Int
romBase = 0x200

-- | Largest ROM that fits in memory (3584 bytes).
maxRomSize :: Int
maxRomSize = memorySize - romBase

-- | Create a machine in its power-on state with the ROM loaded at @0x200@.
-- Bytes of the ROM that would fall beyond @0xFFF@ are ignored.
newMachine :: B.ByteString -> ST s (Machine s)
newMachine rom = do
  mem <- newArray (0, memorySize - 1) 0
  forM_ (zip [fontBase ..] fontBytes) $ \(a, b) -> unsafeWrite mem a b
  forM_ (zip [romBase .. memorySize - 1] (B.unpack rom)) $ \(a, b) -> unsafeWrite mem a b
  v <- newArray (0, 15) 0
  stack <- newArray (0, 15) 0
  disp <- newArray (0, displayWidth * displayHeight - 1) 0
  sc <- newListArray (0, 7) [romBase, 0, 0, 0, 0, 0x12345678, 0, 0]
  pure (Machine mem v stack disp sc)

-- | Replace the 16-bit key state (bit @k@ set = key @k@ held).
setKeys :: Machine s -> Int -> ST s ()
setKeys m = unsafeWrite (mScalars m) rKeys . (.&. 0xFFFF)

-- | Freeze the observable state into an immutable 'Snapshot'.
snapshot :: Machine s -> ST s Snapshot
snapshot m = do
  pc <- unsafeRead (mScalars m) rPC
  i <- unsafeRead (mScalars m) rI
  sp <- unsafeRead (mScalars m) rSP
  dt <- unsafeRead (mScalars m) rDT
  st <- unsafeRead (mScalars m) rST
  vs <- getElems (mV m)
  px <- getElems (mDisplay m)
  pure Snapshot
    { snapPC = pc
    , snapI = i
    , snapSP = sp
    , snapDT = fromIntegral dt
    , snapST = fromIntegral st
    , snapV = listArray (0, 15) vs
    , snapDisplay = listArray (0, displayWidth * displayHeight - 1) (map (/= 0) px)
    }

-- Scalar accessors --------------------------------------------------------

get :: Machine s -> Int -> ST s Int
get m = unsafeRead (mScalars m)
{-# INLINE get #-}

put :: Machine s -> Int -> Int -> ST s ()
put m = unsafeWrite (mScalars m)
{-# INLINE put #-}

setPC :: Machine s -> Int -> ST s ()
setPC m v = put m rPC (v .&. 0xFFF)
{-# INLINE setPC #-}

skip :: Machine s -> ST s ()
skip m = get m rPC >>= \pc -> setPC m (pc + 2)
{-# INLINE skip #-}

readMem :: Machine s -> Int -> ST s Int
readMem m a = fromIntegral <$> unsafeRead (mMem m) (a .&. 0xFFF)
{-# INLINE readMem #-}

writeMem :: Machine s -> Int -> Int -> ST s ()
writeMem m a b = unsafeWrite (mMem m) (a .&. 0xFFF) (fromIntegral b)
{-# INLINE writeMem #-}

getV :: Machine s -> Int -> ST s Int
getV m r = fromIntegral <$> unsafeRead (mV m) (r .&. 0xF)
{-# INLINE getV #-}

setV :: Machine s -> Int -> Int -> ST s ()
setV m r b = unsafeWrite (mV m) (r .&. 0xF) (fromIntegral b)
{-# INLINE setV #-}

-- | Write a result register, then the flag, so the flag wins when the
-- result register is @VF@.
setWithFlag :: Machine s -> Reg -> Int -> Bool -> ST s ()
setWithFlag m x r flag = setV m x r >> setV m 0xF (if flag then 1 else 0)
{-# INLINE setWithFlag #-}

-- | Execute one full cycle: fetch, decode, execute, timer tick.
step :: Machine s -> ST s ()
step m = do
  pc <- get m rPC
  hi <- readMem m pc
  lo <- readMem m (pc + 1)
  setPC m (pc + 2)
  execute m (decode ((hi `shiftL` 8) .|. lo))
  tick m

-- | Advance the cycle counter and, every eighth completed cycle, decrement
-- the non-zero timers.
tick :: Machine s -> ST s ()
tick m = do
  c <- (+ 1) <$> get m rCycles
  put m rCycles c
  when (c .&. 7 == 0) $ do
    dt <- get m rDT
    when (dt > 0) $ put m rDT (dt - 1)
    st <- get m rST
    when (st > 0) $ put m rST (st - 1)

execute :: Machine s -> Instruction -> ST s ()
execute m ins = case ins of
  Cls -> forM_ [0 .. displayWidth * displayHeight - 1] $ \k -> unsafeWrite (mDisplay m) k 0
  Ret -> do
    sp <- get m rSP
    let sp' = max 0 (sp - 1)
    put m rSP sp'
    a <- unsafeRead (mStack m) (sp' .&. 15)
    setPC m (fromIntegral a)
  Jp a -> setPC m a
  Call a -> do
    sp <- get m rSP
    pc <- get m rPC
    unsafeWrite (mStack m) (sp .&. 15) (fromIntegral pc)
    put m rSP (min 16 (sp + 1))
    setPC m a
  SeImm x nn -> getV m x >>= \vx -> when (vx == nn) (skip m)
  SneImm x nn -> getV m x >>= \vx -> when (vx /= nn) (skip m)
  SeReg x y -> do
    vx <- getV m x
    vy <- getV m y
    when (vx == vy) (skip m)
  LdImm x nn -> setV m x nn
  AddImm x nn -> getV m x >>= \vx -> setV m x (vx + nn)
  LdReg x y -> getV m y >>= setV m x
  OrReg x y -> binop x y (.|.)
  AndReg x y -> binop x y (.&.)
  XorReg x y -> binop x y xor
  AddReg x y -> do
    vx <- getV m x
    vy <- getV m y
    let s = vx + vy
    setWithFlag m x s (s > 255)
  SubReg x y -> do
    vx <- getV m x
    vy <- getV m y
    setWithFlag m x (vx - vy) (vx >= vy)
  Shr x -> do
    vx <- getV m x
    setWithFlag m x (vx `shiftR` 1) (testBit vx 0)
  SubnReg x y -> do
    vx <- getV m x
    vy <- getV m y
    setWithFlag m x (vy - vx) (vy >= vx)
  Shl x -> do
    vx <- getV m x
    setWithFlag m x (vx `shiftL` 1) (testBit vx 7)
  SneReg x y -> do
    vx <- getV m x
    vy <- getV m y
    when (vx /= vy) (skip m)
  LdI a -> put m rI a
  JpV0 a -> getV m 0 >>= \v0 -> setPC m (a + v0)
  Rnd x nn -> do
    s <- get m rRng
    let s' = (s * 1103515245 + 12345) .&. 0xFFFFFFFF
    put m rRng s'
    setV m x (((s' `shiftR` 16) .&. 0xFF) .&. nn)
  Drw x y n -> draw x y n
  Skp x -> keyDown x >>= \d -> when d (skip m)
  Sknp x -> keyDown x >>= \d -> when (not d) (skip m)
  LdVDt x -> get m rDT >>= setV m x
  WaitKey x -> do
    keys <- get m rKeys
    if keys == 0
      then get m rPC >>= \pc -> setPC m (pc - 2)
      else setV m x (countTrailingZeros keys)
  LdDtV x -> getV m x >>= put m rDT
  LdStV x -> getV m x >>= put m rST
  AddI x -> do
    vx <- getV m x
    i <- get m rI
    put m rI ((i + vx) .&. 0xFFFF)
  LdFont x -> getV m x >>= \vx -> put m rI (glyphAddress vx)
  Bcd x -> do
    vx <- getV m x
    i <- get m rI
    writeMem m i (vx `div` 100)
    writeMem m (i + 1) ((vx `div` 10) `mod` 10)
    writeMem m (i + 2) (vx `mod` 10)
  StoreRegs x -> do
    i <- get m rI
    forM_ [0 .. x] $ \k -> getV m k >>= writeMem m (i + k)
  LoadRegs x -> do
    i <- get m rI
    forM_ [0 .. x] $ \k -> readMem m (i + k) >>= setV m k
  Nop -> pure ()
  where
    binop x y f = do
      vx <- getV m x
      vy <- getV m y
      setV m x (f vx vy)
    keyDown x = do
      vx <- getV m x
      keys <- get m rKeys
      pure (testBit keys (vx .&. 0xF))
    draw x y n = do
      vx <- getV m x
      vy <- getV m y
      i <- get m rI
      let !sx = vx .&. 63
          !sy = vy .&. 31
      setV m 0xF 0
      forM_ [0 .. n - 1] $ \row -> do
        byte <- readMem m (i + row)
        let !py = (sy + row) .&. 31
        forM_ [0 .. 7] $ \bit -> when (testBit byte (7 - bit)) $ do
          let !idx = py * displayWidth + ((sx + bit) .&. 63)
          old <- unsafeRead (mDisplay m) idx
          when (old /= 0) (setV m 0xF 1)
          unsafeWrite (mDisplay m) idx (old `xor` 1)

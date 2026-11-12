-- |
-- Module      : Chip8.Execute
-- Description : The fetch-decode-execute cycle.
--
-- Every cycle fetches the opcode from memory and decodes it afresh; nothing is
-- cached, so self-modifying programs behave correctly.
module Chip8.Execute
  ( step
  , tickTimers
  , runCycles
  ) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST)
import Data.Bits (countTrailingZeros, shiftL, shiftR, testBit, (.&.), (.|.), xor)

import Chip8.Font (fontBase, glyphSize)
import Chip8.Machine
import Chip8.Types

-- | Fetch, decode and execute one instruction.  Does not touch the timers.
step :: Machine s -> ST s ()
step m = do
  pc <- getPC m
  hi <- readMem m pc
  lo <- readMem m (pc + 1)
  setPC m (pc + 2)
  execute m ((hi `shiftL` 8) .|. lo)

-- | Decrement the delay and sound timers, each saturating at zero.
tickTimers :: Machine s -> ST s ()
tickTimers m = do
  dt <- getDT m
  when (dt > 0) $ setDT m (dt - 1)
  st <- getST m
  when (st > 0) $ setST m (st - 1)

-- | Run exactly @n@ cycles.  The key schedule must be in increasing cycle
-- order; it is consumed front to back, so the cost is O(1) per cycle.
runCycles :: Machine s -> Int -> [KeyEvent] -> ST s ()
runCycles m n = go 0
  where
    go !c events
      | c >= n = pure ()
      | otherwise = do
          events' <- applyKeys c events
          step m
          let c' = c + 1
          when (c' .&. 7 == 0) $ tickTimers m
          go c' events'
    applyKeys c events@(KeyEvent ec mask : rest)
      | ec <= c = setKeys m mask >> applyKeys c rest
      | otherwise = pure events
    applyKeys _ [] = pure []

skipIf :: Machine s -> Bool -> ST s ()
skipIf m cond = when cond $ getPC m >>= \pc -> setPC m (pc + 2)
{-# INLINE skipIf #-}

-- | Write @VX@ first and the flag to @VF@ afterwards, so the flag wins when
-- @X = F@.
setWithFlag :: Machine s -> Int -> Int -> Int -> ST s ()
setWithFlag m x val flag = writeV m x val >> writeV m 15 flag
{-# INLINE setWithFlag #-}

execute :: Machine s -> Int -> ST s ()
execute m op = case op `shiftR` 12 of
  0x0 -> case op of
    0x00E0 -> clearDisplay m
    0x00EE -> pop m >>= setPC m
    _      -> pure ()
  0x1 -> setPC m nnn
  0x2 -> getPC m >>= push m >> setPC m nnn
  0x3 -> readV m x >>= \vx -> skipIf m (vx == nn)
  0x4 -> readV m x >>= \vx -> skipIf m (vx /= nn)
  0x5 | n == 0 -> do
          vx <- readV m x
          vy <- readV m y
          skipIf m (vx == vy)
  0x6 -> writeV m x nn
  0x7 -> readV m x >>= \vx -> writeV m x (vx + nn)
  0x8 -> alu
  0x9 | n == 0 -> do
          vx <- readV m x
          vy <- readV m y
          skipIf m (vx /= vy)
  0xA -> setI m nnn
  0xB -> readV m 0 >>= \v0 -> setPC m (nnn + v0)
  0xC -> do
    r <- nextRandomByte m
    writeV m x (r .&. nn)
  0xD -> draw
  0xE -> case nn of
    0x9E -> keyDown >>= skipIf m
    0xA1 -> keyDown >>= skipIf m . not
    _    -> pure ()
  0xF -> misc
  _   -> pure ()
  where
    x = (op `shiftR` 8) .&. 0xF
    y = (op `shiftR` 4) .&. 0xF
    n = op .&. 0xF
    nn = op .&. 0xFF
    nnn = op .&. 0xFFF

    keyDown = do
      vx <- readV m x
      keys <- getKeys m
      pure (testBit keys (vx .&. 0xF))

    alu = do
      vx <- readV m x
      vy <- readV m y
      case n of
        0x0 -> writeV m x vy
        0x1 -> writeV m x (vx .|. vy)
        0x2 -> writeV m x (vx .&. vy)
        0x3 -> writeV m x (vx `xor` vy)
        0x4 -> let s = vx + vy in setWithFlag m x s (fromEnum (s > 255))
        0x5 -> setWithFlag m x (vx - vy) (fromEnum (vx >= vy))
        0x6 -> setWithFlag m x (vx `shiftR` 1) (vx .&. 1)
        0x7 -> setWithFlag m x (vy - vx) (fromEnum (vy >= vx))
        0xE -> setWithFlag m x (vx `shiftL` 1) ((vx `shiftR` 7) .&. 1)
        _   -> pure ()

    draw = do
      sx <- (.&. 63) <$> readV m x
      sy <- (.&. 31) <$> readV m y
      i <- getI m
      writeV m 15 0
      forM_ [0 .. n - 1] $ \row -> do
        byte <- readMem m (i + row)
        forM_ [0 .. 7] $ \bit ->
          when (testBit byte (7 - bit)) $ do
            wasLit <- xorPixel m (sx + bit) (sy + row)
            when wasLit $ writeV m 15 1

    misc = case nn of
      0x07 -> getDT m >>= writeV m x
      0x0A -> do
        keys <- getKeys m
        if keys .&. 0xFFFF == 0
          then getPC m >>= \pc -> setPC m (pc - 2)
          else writeV m x (countTrailingZeros keys)
      0x15 -> readV m x >>= setDT m
      0x18 -> readV m x >>= setST m
      0x1E -> do
        vx <- readV m x
        i <- getI m
        setI m (i + vx)
      0x29 -> readV m x >>= \vx -> setI m (fontBase + (vx .&. 0xF) * glyphSize)
      0x33 -> do
        vx <- readV m x
        i <- getI m
        writeMem m i (vx `div` 100)
        writeMem m (i + 1) ((vx `div` 10) `mod` 10)
        writeMem m (i + 2) (vx `mod` 10)
      0x55 -> do
        i <- getI m
        forM_ [0 .. x] $ \k -> readV m k >>= writeMem m (i + k)
      0x65 -> do
        i <- getI m
        forM_ [0 .. x] $ \k -> readMem m (i + k) >>= writeV m k
      _ -> pure ()

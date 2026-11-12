{-# LANGUAGE BangPatterns #-}
-- |
-- Module      : Chip8.Run
-- Description : Running a ROM for a fixed number of cycles.
module Chip8.Run
  ( runRom
  , runInput
  ) where

import Control.Monad.ST (ST, runST)
import qualified Data.ByteString as B

import Chip8.Input
import Chip8.Machine
import Chip8.Snapshot

-- | Run a ROM for exactly @n@ cycles under a key schedule and return the
-- final state.
--
-- The schedule must be in increasing cycle order; it is consumed from the
-- front, so each cycle costs O(1) regardless of its length.
runRom :: B.ByteString -> Int -> [KeyEvent] -> Snapshot
runRom rom n events = runST $ do
  m <- newMachine rom
  loop m 0 events
  snapshot m
  where
    loop :: Machine s -> Int -> [KeyEvent] -> ST s ()
    loop m !c evs
      | c >= n = pure ()
      | otherwise = do
          evs' <- case evs of
            (KeyEvent ec mask : rest) | ec == c -> setKeys m mask >> pure rest
            _ -> pure evs
          step m
          loop m (c + 1) evs'

-- | 'runRom' on a parsed 'Input'.
runInput :: Input -> Snapshot
runInput (Input rom n evs) = runRom rom n evs

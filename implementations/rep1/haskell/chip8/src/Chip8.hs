-- |
-- Module      : Chip8
-- Description : A deterministic CHIP-8 interpreter.
--
-- The usual entry points are 'parseInput' (text to 'Input'), 'run' (execute a
-- program and get a 'Snapshot') and 'renderSnapshot' (snapshot to text):
--
-- > case parseInput txt of
-- >   Left err -> putStrLn err
-- >   Right inp -> putStr (renderSnapshot (run inp))
--
-- For finer control use "Chip8.Machine" and "Chip8.Execute" to drive a
-- machine in 'ST' yourself.
module Chip8
  ( -- * Running programs
    run
  , runRom
    -- * Re-exports
  , module Chip8.Types
  , module Chip8.Input
  , module Chip8.Render
  ) where

import Control.Monad.ST (runST)

import Chip8.Execute (runCycles)
import Chip8.Input
import Chip8.Machine (freezeMachine, newMachine)
import Chip8.Render
import Chip8.Types

-- | Run a parsed 'Input' to completion.
run :: Input -> Snapshot
run (Input rom n keys) = runRom rom n keys

-- | Load a ROM, execute exactly @n@ cycles under the given key schedule and
-- return the final state.
runRom :: Rom -> Int -> [KeyEvent] -> Snapshot
runRom rom n keys = runST $ do
  m <- newMachine rom
  runCycles m n keys
  freezeMachine m

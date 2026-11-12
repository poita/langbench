module Main (main) where

import Test.Hspec

import qualified Chip8.InputSpec
import qualified Chip8.InstructionSpec
import qualified Chip8.MachineSpec
import qualified Chip8.OutputSpec
import qualified Chip8.RunSpec

main :: IO ()
main = hspec $ do
  describe "Chip8.Input" Chip8.InputSpec.spec
  describe "Chip8.Instruction" Chip8.InstructionSpec.spec
  describe "Chip8.Machine" Chip8.MachineSpec.spec
  describe "Chip8.Output" Chip8.OutputSpec.spec
  describe "Chip8.Run" Chip8.RunSpec.spec

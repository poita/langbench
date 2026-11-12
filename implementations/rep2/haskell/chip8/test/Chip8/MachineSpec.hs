module Chip8.MachineSpec (spec) where

import Control.Monad.ST (runST)
import qualified Data.ByteString as B
import Test.Hspec
import Test.QuickCheck

import Chip8
import Chip8.Machine
import Chip8.TestUtil

spec :: Spec
spec = do
  it "starts in the power-on state" $ do
    let s = runST (newMachine B.empty >>= snapshot)
    snapPC s `shouldBe` 0x200
    snapI s `shouldBe` 0
    snapSP s `shouldBe` 0
    regs s `shouldBe` replicate 16 0
  it "step executes one instruction" $ do
    let s = runST (newMachine (romOf [0x6A2B]) >>= \m -> step m >> snapshot m)
    regs s !! 0xA `shouldBe` 0x2B
    snapPC s `shouldBe` 0x202
  it "8XY4 sets VX then the carry flag" $ do
    let s = runOps [0x60FF, 0x6102, 0x8014] 3
    take 2 (regs s) `shouldBe` [1, 2]
    regs s !! 0xF `shouldBe` 1
  it "the flag wins when X = F" $ do
    let s = runOps [0x6FFF, 0x6101, 0x8F14] 3
    regs s !! 0xF `shouldBe` 1
  it "8XY5 / 8XY7 borrow flags" $ do
    regs (runOps [0x6005, 0x6105, 0x8015] 3) !! 0xF `shouldBe` 1
    regs (runOps [0x6004, 0x6105, 0x8015] 3) !! 0xF `shouldBe` 0
    regs (runOps [0x6005, 0x6104, 0x8017] 3) !! 0xF `shouldBe` 0
  it "shifts use VX in place" $ do
    let s = runOps [0x6081, 0x61FF, 0x806E, 0x8106] 4
    take 2 (regs s) `shouldBe` [0x02, 0x7F]
    regs s !! 0xF `shouldBe` 1
  it "call and return use the stack" $ do
    let s = runOps [0x2204, 0x1202, 0x00EE] 1
    snapSP s `shouldBe` 1
    snapPC s `shouldBe` 0x204
    let s' = runOps [0x2204, 0x1202, 0x00EE] 2
    snapSP s' `shouldBe` 0
    snapPC s' `shouldBe` 0x202
  it "BNNN adds V0 and wraps; PC may become odd" $ do
    let s = runOps [0x6001, 0xBFFF] 2
    snapPC s `shouldBe` 0x000
    snapPC (runOps [0x6001, 0xB300] 2) `shouldBe` 0x301
  it "fetch at 0xFFF wraps the low byte to 0x000" $ do
    let s = runOps [0xBFFE, 0x0000] 0
    snapPC s `shouldBe` 0x200
    snapPC (runOps [0x60FF, 0xBF00] 2) `shouldBe` 0xFFF
  it "FX33 stores BCD digits" $ do
    -- V0=254, I=0x300, BCD, V0..V2 <- mem[I..I+2]
    let s = runOps [0x60FE, 0xA300, 0xF033, 0xF265] 4
    take 3 (regs s) `shouldBe` [2, 5, 4]
  it "FX55 / FX65 do not modify I" $ do
    let s = runOps [0x6001, 0x6102, 0xA300, 0xF155, 0xF165] 5
    snapI s `shouldBe` 0x300
  it "FX1E keeps 16 bits of I" $ do
    let s = runOps [0xAFFF, 0x60FF, 0xF01E, 0xF01E] 4
    snapI s `shouldBe` (0xFFF + 2 * 0xFF)
  it "FX0A waits, re-executing, until a key is held" $ do
    let s = runRom (romOf [0xF00A]) 5 []
    snapPC s `shouldBe` 0x200
    let s' = runRom (romOf [0xF00A]) 5 [KeyEvent 3 0x0090]
    snapPC s' `shouldBe` 0x204 -- completed in cycle 3, then two no-ops
    regs s' !! 0 `shouldBe` 4
  it "EX9E / EXA1 test the key state" $ do
    let rom = romOf [0x6003, 0xE09E, 0x6101, 0x6201]
    -- key 3 down: the "6101" is skipped; key 3 up: it runs
    take 3 (regs (runRom rom 4 [KeyEvent 0 0x0008])) `shouldBe` [3, 0, 1]
    take 3 (regs (runRom rom 4 [])) `shouldBe` [3, 1, 1]
  it "draw wraps and reports collisions" $ do
    let ops = [0x6A3E, 0x6B1E, 0x6000, 0xF029, 0xDAB5, 0xDAB5]
        s5 = runOps ops 5
    pixelAt s5 62 30 `shouldBe` True
    pixelAt s5 0 2 `shouldBe` True
    pixelAt s5 1 2 `shouldBe` True
    pixelAt s5 63 31 `shouldBe` False
    regs s5 !! 0xF `shouldBe` 0
    let s6 = runOps ops 6
    regs s6 !! 0xF `shouldBe` 1
    or [pixelAt s6 x y | x <- [0 .. 63], y <- [0 .. 31]] `shouldBe` False
  it "CXNN follows the specified LCG" $ do
    let s = runOps [0xC0FF, 0xC1FF, 0xC20F] 3
    take 3 (regs s) `shouldBe` [0x71, 0x47, 0x0D]
  it "CXNN with NN=0 still advances the generator" $ do
    let s = runOps [0xC000, 0xC1FF] 2
    regs s !! 1 `shouldBe` 0x47
  it "timers tick after every eighth cycle" $ do
    let s = runOps ([0x6010, 0xF015, 0xF018] ++ replicate 20 0) 8
    snapDT s `shouldBe` 0x0F
    snapST s `shouldBe` 0x0F
  it "FX15 in the eighth cycle is decremented immediately" $ do
    let s = runOps (replicate 7 0x0000 ++ [0xF015]) 8
    snapDT s `shouldBe` 0
    snapDT (runOps (0x6005 : replicate 6 0 ++ [0xF015]) 8) `shouldBe` 4
  it "register 8XY0..8XY3 leave VF alone" $
    property $ \a b -> let (x, y) = (a `mod` 256, b `mod` 256) in
      regs (runOps [0x6F77, 0x6000 + x, 0x6100 + y, 0x8011, 0x8012, 0x8013] 6) !! 0xF == 0x77
  it "7XNN adds modulo 256 without touching VF" $
    property $ \a b -> let (x, y) = (a `mod` 256, b `mod` 256) in
      let s = runOps [0x6000 + x, 0x7000 + y] 2
      in regs s !! 0 == fromIntegral ((x + y) `mod` 256) && regs s !! 0xF == 0

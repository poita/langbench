module Chip8.InstructionSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Chip8

spec :: Spec
spec = do
  it "decodes the basic instructions" $ do
    decode 0x00E0 `shouldBe` Cls
    decode 0x00EE `shouldBe` Ret
    decode 0x1234 `shouldBe` Jp 0x234
    decode 0x2ABC `shouldBe` Call 0xABC
    decode 0x3A42 `shouldBe` SeImm 0xA 0x42
    decode 0x8AB4 `shouldBe` AddReg 0xA 0xB
    decode 0x8AB6 `shouldBe` Shr 0xA
    decode 0xD125 `shouldBe` Drw 1 2 5
    decode 0xF755 `shouldBe` StoreRegs 7
  it "treats unassigned opcodes as no-ops" $
    mapM_ (\op -> decode op `shouldBe` Nop)
      [0x0000, 0x0123, 0x5AB1, 0x8AB8, 0x9AB3, 0xE000, 0xF0FF]
  it "decodes every opcode without failing" $
    property $ \(Positive w) -> let op = w `mod` 0x10000 in decode op == decode op

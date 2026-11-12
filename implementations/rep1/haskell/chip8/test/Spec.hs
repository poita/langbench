module Main (main) where

import Control.Monad (replicateM)
import Control.Monad.ST (runST)
import Data.Array.Unboxed ((!))
import Data.Char (intToDigit)
import Data.Word (Word8)
import Test.Hspec
import Test.QuickCheck

import Chip8
import Chip8.Font (fontBase, fontData)
import Chip8.Machine (newMachine, nextRandomByte)

-- | Assemble opcodes into a ROM.
rom :: [Int] -> Rom
rom = concatMap (\op -> [fromIntegral (op `div` 256), fromIntegral (op `mod` 256)])

-- | Run opcodes for n cycles with no keys.
exec :: [Int] -> Int -> Snapshot
exec ops n = runRom (rom ops) n []

reg :: Snapshot -> Int -> Int
reg s r = fromIntegral (snapV s ! r)

hexOf :: [Word8] -> String
hexOf = concatMap (\b -> [intToDigit (fromIntegral b `div` 16), intToDigit (fromIntegral b `mod` 16)])

-- | Run text through the full parse / run / render pipeline.
pipeline :: String -> String
pipeline txt = either error (renderSnapshot . run) (parseInput txt)

blankRows :: String
blankRows = concat (replicate 32 (replicate 64 '.' ++ "\n"))

main :: IO ()
main = hspec $ do
  describe "specification examples" $ do
    it "example 1: arithmetic and a self-loop" $
      pipeline "60ff7001610180141208\n6\n" `shouldBe`
        blankRows ++ "PC=0208 I=0000 SP=0 DT=00 ST=00\n\
                     \V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
    it "example 2: wrapping draw" $ do
      let out = lines (pipeline "6a3e6b1e6000f029dab5dab5\n5\n")
      take 3 out `shouldBe`
        [ ".#............................................................#."
        , ".#............................................................#."
        , "##............................................................##" ]
      out !! 31 `shouldBe` ".#............................................................#."
      out !! 32 `shouldBe` "PC=020a I=0050 SP=0 DT=00 ST=00"
    it "example 2: second draw erases and sets VF" $
      pipeline "6a3e6b1e6000f029dab5dab5\n6\n" `shouldBe`
        blankRows ++ "PC=020c I=0050 SP=0 DT=00 ST=00\n\
                     \V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01\n"
    it "example 3: random numbers, timers and keys" $
      pipeline "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n"
        `shouldBe` blankRows ++ "PC=021e I=0000 SP=0 DT=07 ST=00\n\
                                \V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n"

  describe "Chip8.Input.parseInput" $ do
    it "accepts a missing key schedule and trailing newline" $
      parseInput "00e0\n0" `shouldBe` Right (Input [0x00, 0xe0] 0 [])
    it "parses key events" $
      fmap inputKeys (parseInput "00e0\n5\n1:0003 4:0000\n")
        `shouldBe` Right [KeyEvent 1 3, KeyEvent 4 0]
    it "treats an empty third line as no events" $
      fmap inputKeys (parseInput "00e0\n5\n\n") `shouldBe` Right []
    it "rejects odd-length ROMs" $
      parseInput "00e\n1\n" `shouldSatisfy` either (const True) (const False)
    it "rejects malformed key events" $
      parseInput "00e0\n1\n1-0001\n" `shouldSatisfy` either (const True) (const False)
    it "round-trips any ROM" $ property $ \bytes ->
      not (null bytes) ==>
        fmap inputRom (parseInput (hexOf bytes ++ "\n0\n")) === Right bytes

  describe "machine model" $ do
    it "starts with the font and ROM in place" $ do
      let s = exec [0x1200] 0
      [ snapMemory s ! (fontBase + k) | k <- [0 .. 79] ] `shouldBe` fontData
      snapMemory s ! 0x200 `shouldBe` 0x12
      snapPC s `shouldBe` 0x200
    it "does nothing for zero cycles" $
      renderSnapshot (exec [0x6001] 0) `shouldBe`
        blankRows ++ "PC=0200 I=0000 SP=0 DT=00 ST=00\n\
                     \V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
    it "produces 34 lines of the right shape" $ do
      let out = lines (renderSnapshot (exec [0xF029, 0xD005] 2))
      length out `shouldBe` 34
      all ((== 64) . length) (take 32 out) `shouldBe` True
    it "generates the specified RNG sequence" $ do
      let bytes = runST $ do
            m <- newMachine []
            replicateM 3 (nextRandomByte m)
      bytes `shouldBe` [0x71, 0x47, 0x1d]

  describe "instructions" $ do
    it "calls and returns" $ do
      let s = exec [0x2204, 0x1202, 0x00EE] 1
      snapSP s `shouldBe` 1
      snapPC s `shouldBe` 0x204
      let s' = exec [0x2204, 0x1202, 0x00EE] 2
      snapSP s' `shouldBe` 0
      snapPC s' `shouldBe` 0x202
    it "can fill the whole stack" $
      snapSP (exec (replicate 16 0x2202 ++ []) 16) `shouldBe` 16
    it "skips with 3XNN / 4XNN / 5XY0 / 9XY0" $ do
      snapPC (exec [0x6005, 0x3005] 2) `shouldBe` 0x206
      snapPC (exec [0x6005, 0x4005] 2) `shouldBe` 0x204
      snapPC (exec [0x5010] 1) `shouldBe` 0x204
      snapPC (exec [0x9010] 1) `shouldBe` 0x202
    it "treats unknown opcodes as no-ops" $ do
      snapPC (exec [0x5011, 0x8018, 0x9013, 0xE000, 0xF0FF, 0x0123] 6) `shouldBe` 0x20c
    it "8XY4 sets the carry" $ do
      let s = exec [0x60FF, 0x6102, 0x8014] 3
      (reg s 0, reg s 15) `shouldBe` (1, 1)
    it "8XY5 / 8XY7 flag means no borrow" $ do
      let s = exec [0x6003, 0x6105, 0x8015] 3
      (reg s 0, reg s 15) `shouldBe` (254, 0)
      let t = exec [0x6003, 0x6105, 0x8017] 3
      (reg t 0, reg t 15) `shouldBe` (2, 1)
    it "shifts VX in place" $ do
      let s = exec [0x6003, 0x61F0, 0x8016] 3
      (reg s 0, reg s 15) `shouldBe` (1, 1)
      let t = exec [0x6081, 0x800E] 2
      (reg t 0, reg t 15) `shouldBe` (2, 1)
    it "lets the flag win when X = F" $ do
      let s = exec [0x6F01, 0x6001, 0x8F04] 3
      reg s 15 `shouldBe` 0
      let t = exec [0x6FFF, 0x6001, 0x8F04] 3
      reg t 15 `shouldBe` 1
    it "BNNN adds V0 and wraps" $ do
      snapPC (exec [0x60FF, 0xBFFF] 2) `shouldBe` 0x0FE
    it "FX0A waits, then stores the lowest key" $ do
      let r = rom [0xF00A]
      snapPC (runRom r 3 []) `shouldBe` 0x200
      let s = runRom r 2 [KeyEvent 1 0x0A00]
      (reg s 0, snapPC s) `shouldBe` (9, 0x202)
    it "FX33 / FX55 / FX65 wrap addresses" $ do
      let s = exec [0x60FF, 0xAFFF, 0xF033] 3
      (snapMemory s ! 0xFFF, snapMemory s ! 0, snapMemory s ! 1) `shouldBe` (2, 5, 5)
      let t = exec [0x6011, 0x6122, 0xAFFF, 0xF155, 0xF165] 5
      (snapMemory t ! 0xFFF, snapMemory t ! 0, snapI t) `shouldBe` (0x11, 0x22, 0xFFF)
    it "FX1E keeps I above 0xFFF" $
      snapI (exec [0xAFFF, 0x60FF, 0xF01E] 3) `shouldBe` 0x10FE
    it "timers tick after every eighth cycle" $ do
      let s = exec (0x600A : 0xF015 : 0xF018 : replicate 20 0x1206) 16
      (snapDT s, snapST s) `shouldBe` (8, 8)
    it "keeps registers in 8 bits" $ property $ \a b ->
      let s = exec [0x6000 + fromIntegral (a :: Word8), 0x7000 + fromIntegral (b :: Word8)] 2
      in reg s 0 === (fromIntegral a + fromIntegral b) `mod` 256

  describe "DXYN" $ do
    it "draws nothing for N = 0 and clears VF" $ do
      let s = exec [0x6F01, 0xD000] 2
      reg s 15 `shouldBe` 0
      all not (map (pixelAt s 0) [0 .. 31]) `shouldBe` True
    it "XOR-ing twice erases the sprite" $ property $ \(x, y) ->
      let s = exec [0x6000 + fromIntegral (x :: Word8), 0x6100 + fromIntegral (y :: Word8)
                   , 0xF029, 0xD015, 0xD015] 5
      in conjoin [ not (pixelAt s i j) | i <- [0 .. 63], j <- [0 .. 31] ]
    it "00E0 clears the display" $ do
      let s = exec [0xF029, 0xD015, 0x00E0] 3
      or [ pixelAt s i j | i <- [0 .. 63], j <- [0 .. 31] ] `shouldBe` False

  describe "run" $ do
    it "is deterministic and executes self-modified code" $ do
      -- Overwrite the instruction at 0x208 with 6A77 via memory writes.
      let ops = [0x606A, 0x6177, 0xA208, 0xF155, 0x0000, 0x0000]
          s = exec ops 5
      reg s 10 `shouldBe` 0x77
    it "splits runs consistently: key schedule events at cycle N never apply" $
      exec [0xF00A] 4 `shouldBe` runRom (rom [0xF00A]) 4 [KeyEvent 4 1]

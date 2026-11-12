module Chip8.InputSpec (spec) where

import qualified Data.ByteString as B
import Test.Hspec

import Chip8

spec :: Spec
spec = do
  it "parses ROM, cycles and key schedule" $
    parseInput "60ff\n12\n9:0300 12:0000\n"
      `shouldBe` Right (Input (B.pack [0x60, 0xff]) 12 [KeyEvent 9 0x300, KeyEvent 12 0])
  it "accepts a missing trailing newline" $
    parseInput "6001\n3" `shouldBe` Right (Input (B.pack [0x60, 1]) 3 [])
  it "treats an empty third line as no events" $
    parseInput "6001\n3\n\n" `shouldBe` Right (Input (B.pack [0x60, 1]) 3 [])
  it "rejects an odd-length ROM" $
    parseInput "600\n3\n" `shouldSatisfy` isLeft
  it "rejects a too-long ROM" $
    parseInput (replicate 7170 '0' ++ "\n1\n") `shouldSatisfy` isLeft
  it "rejects events out of order" $
    parseInput "6001\n9\n5:0001 5:0002\n" `shouldSatisfy` isLeft
  it "rejects a malformed event" $
    parseInput "6001\n9\n5:01\n" `shouldSatisfy` isLeft
  it "rejects missing cycle count" $
    parseInput "6001\n" `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)

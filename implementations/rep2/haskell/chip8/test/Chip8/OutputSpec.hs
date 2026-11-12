module Chip8.OutputSpec (spec) where

import Test.Hspec

import Chip8
import Chip8.TestUtil

spec :: Spec
spec = do
  it "renders 34 lines, display first" $ do
    let ls = lines (render (runOps [0x6001] 1))
    length ls `shouldBe` 34
    all ((== 64) . length) (take 32 ls) `shouldBe` True
    ls !! 32 `shouldBe` "PC=0202 I=0000 SP=0 DT=00 ST=00"
    ls !! 33 `shouldBe` "V=01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
  it "ends with a newline" $
    last (render (runOps [0x6001] 0)) `shouldBe` '\n'
  it "draws lit pixels as # and unlit as ." $ do
    let ls = lines (render (runOps [0xA050, 0xD005] 2))
    take 5 ls `shouldBe`
      [ "####" ++ replicate 60 '.'
      , "#..#" ++ replicate 60 '.'
      , "#..#" ++ replicate 60 '.'
      , "#..#" ++ replicate 60 '.'
      , "####" ++ replicate 60 '.'
      ]
    ls !! 32 `shouldBe` "PC=0204 I=0050 SP=0 DT=00 ST=00"

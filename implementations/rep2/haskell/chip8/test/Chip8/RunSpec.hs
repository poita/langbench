module Chip8.RunSpec (spec) where

import Test.Hspec

import Chip8

-- | Run the textual pipeline: parse, run, render.
pipeline :: String -> String
pipeline = either error (render . runInput) . parseInput

blank :: String
blank = unlines (replicate 32 (replicate 64 '.'))

spec :: Spec
spec = do
  it "example 1: arithmetic and a self-loop" $
    pipeline "60ff7001610180141208\n6\n"
      `shouldBe` blank ++ "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
  it "example 2: wrapped draw leaves VF clear" $ do
    let out = lines (pipeline "6a3e6b1e6000f029dab5dab5\n5\n")
    take 4 out `shouldBe`
      [ ".#" ++ replicate 60 '.' ++ "#."
      , ".#" ++ replicate 60 '.' ++ "#."
      , "##" ++ replicate 60 '.' ++ "##"
      , replicate 64 '.'
      ]
    drop 32 out `shouldBe`
      [ "PC=020a I=0050 SP=0 DT=00 ST=00"
      , "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00"
      ]
  it "example 3: random numbers, timers and keys" $
    drop 32 (lines (pipeline "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n"))
      `shouldBe`
        [ "PC=021e I=0000 SP=0 DT=07 ST=00"
        , "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00"
        ]
  it "zero cycles executes nothing" $
    pipeline "6001\n0\n" `shouldBe` blank ++ "PC=0200 I=0000 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"
  it "an event at cycle N never takes effect" $
    drop 32 (lines (pipeline "f00a\n3\n3:0001\n"))
      `shouldBe`
        [ "PC=0200 I=0000 SP=0 DT=00 ST=00"
        , "V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        ]
  it "a later event can release keys again" $
    drop 32 (lines (pipeline "f00af10a\n3\n1:0004 2:0000\n"))
      `shouldBe`
        [ "PC=0202 I=0000 SP=0 DT=00 ST=00"
        , "V=02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        ]

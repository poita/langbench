module Typeset.HyphenationSpec (spec) where

import Test.Hspec

import Typeset.Font (ioReadUtf8)
import Typeset.Hyphenation

spec :: Spec
spec = do
  english <- runIO (parsePatterns <$> ioReadUtf8 "data/hyphen/english.chp")
  minimal <- runIO (parsePatterns <$> ioReadUtf8 "data/hyphen/minimal.chp")
  describe "pattern files" $ do
    it "reads the minima" $ do
      (patLeft english, patRight english) `shouldBe` (2, 3)
      (patLeft minimal, patRight minimal) `shouldBe` (2, 2)
  describe "liangBreaks (english)" $ do
    it "matches the worked traces" $ do
      liangBreaks english "winter" `shouldBe` [3]
      liangBreaks english "typesetting" `shouldBe` [7, 8]
      liangBreaks english "national" `shouldBe` [2, 4]
      liangBreaks english "introduction" `shouldBe` [2, 8]
    it "prefers exceptions over patterns" $
      liangBreaks english "algorithm" `shouldBe` [2, 4]
    it "never breaks short words" $
      liangBreaks english "the" `shouldBe` []
  describe "liangBreaks (minimal)" $
    it "uses its own exceptions" $
      liangBreaks minimal "hyphen" `shouldBe` [2]

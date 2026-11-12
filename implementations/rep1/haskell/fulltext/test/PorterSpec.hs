module PorterSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Fulltext.Porter

spec :: Spec
spec = do
  describe "stem" $ do
    let table =
          [ ("caresses", "caress"), ("ponies", "poni"), ("ties", "ti"), ("cats", "cat")
          , ("feed", "feed"), ("agreed", "agre"), ("need", "need"), ("bleed", "bleed")
          , ("plastered", "plaster"), ("motoring", "motor"), ("sing", "sing")
          , ("conflated", "conflat"), ("troubled", "troubl"), ("sized", "size")
          , ("hopping", "hop"), ("falling", "fall"), ("filing", "file"), ("failing", "fail")
          , ("happy", "happi"), ("sky", "sky"), ("relational", "relat")
          , ("conditional", "condit"), ("running", "run"), ("runs", "run")
          , ("runner", "runner"), ("connection", "connect"), ("happiness", "happi")
          , ("happier", "happier"), ("relativity", "rel"), ("sensibility", "sensibl")
          , ("national", "nation"), ("controlled", "control"), ("abandoned", "abandon")
          , ("probate", "probat"), ("rate", "rate"), ("cease", "ceas"), ("roll", "roll")
          , ("is", "is"), ("a", "a")
          ]
    mapM_ (\(w, s) -> it (w ++ " -> " ++ s) $ stem w `shouldBe` s) table

  describe "measure" $ do
    mapM_ (\(w, m) -> it w $ measure w `shouldBe` m)
      [ ("tr", 0), ("ee", 0), ("tree", 0), ("y", 0), ("by", 0)
      , ("trouble", 1), ("oats", 1), ("trees", 1), ("ivy", 1)
      , ("troubles", 2), ("private", 2), ("oaten", 2) ]

  it "reproduces Porter's published vocabulary (23531 words)" $ do
    ws <- lines <$> readFile "test/data/porter-voc.txt"
    ss <- lines <$> readFile "test/data/porter-output.txt"
    length ws `shouldBe` length ss
    let bad = [ (w, s, stem w) | (w, s) <- zip ws ss, stem w /= s ]
    take 5 bad `shouldBe` []

  it "never lengthens a word by more than one letter" $
    property $ forAll (listOf1 (elements ['a' .. 'z'])) $ \w ->
      length (stem w) <= length w + 1

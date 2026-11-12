module Typeset.UnitsSpec (spec) where

import Test.Hspec
import Test.QuickCheck hiding (scale)

import Typeset.Units

spec :: Spec
spec = do
  describe "scale" $ do
    it "uses floor division, also for negative kerns" $ do
      scale 1563 10000 `shouldBe` 15630
      scale (-60) 11000 `shouldBe` (-660)
      scale (-1) 1 `shouldBe` (-1)
  describe "size steps" $ do
    it "step up and down follow the spec" $ do
      stepUp 10000 `shouldBe` 12000
      stepDown 10000 `shouldBe` 8333
      stepUp (stepDown 10000) `shouldBe` 9999
  describe "roman" $ do
    it "handles the usual numerals" $ do
      map roman [1, 4, 9, 14, 40, 2026] `shouldBe` ["i", "iv", "ix", "xiv", "xl", "mmxxvi"]
    it "applies the greedy rule above 3999" $ do
      roman 4000 `shouldBe` "mmmm"
      roman 5001 `shouldBe` "mmmmmi"
    it "round-trips through a decoder" $
      property $ forAll (choose (1, 3999)) $ \n -> decode (roman n) === n
  describe "alphaLabel" $ do
    it "is bijective base 26" $ do
      map alphaLabel [1, 26, 27, 28, 52, 53] `shouldBe` ["a", "z", "aa", "ab", "az", "ba"]
    it "is injective" $
      property $ forAll (choose (1, 5000)) $ \a -> forAll (choose (1, 5000)) $ \b ->
        (alphaLabel a == alphaLabel b) === (a == b)
  describe "cube100Div" $ do
    it "matches the worked examples" $ do
      cube100Div 11020 6350 `shouldBe` 522
      cube100Div 3890 5100 `shouldBe` 44
    it "agrees with Integer arithmetic even for huge inputs" $
      property $ forAll (choose (0, 3000000)) $ \d -> forAll (choose (1, 3000000)) $ \y ->
        toInteger (cube100Div d y) === (100 * toInteger d ^ (3 :: Int)) `div` (toInteger y ^ (3 :: Int))

-- | Decode a lowercase roman numeral (test helper).
decode :: String -> Int
decode s = go (map val s)
  where
    val c = case c of
      'm' -> 1000; 'd' -> 500; 'c' -> 100; 'l' -> 50; 'x' -> 10; 'v' -> 5; _ -> 1
    go (a : b : r) | a < b = b - a + go r
                   | otherwise = a + go (b : r)
    go [a] = a
    go [] = 0

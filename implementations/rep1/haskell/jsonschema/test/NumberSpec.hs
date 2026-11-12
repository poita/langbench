module NumberSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import JsonSchema.Number

spec :: Spec
spec = do
  it "normalises equal values to equal numbers" $ do
    mkNumber 100 0 `shouldBe` mkNumber 1 2
    mkNumber 10 (-1) `shouldBe` mkNumber 1 0
    mkNumber 0 5 `shouldBe` mkNumber 0 (-7)

  it "recognises integers" $ do
    isInteger (mkNumber 10 (-1)) `shouldBe` True
    isInteger (mkNumber 1 2) `shouldBe` True
    isInteger (mkNumber 15 (-1)) `shouldBe` False

  it "compares exactly beyond double range" $ do
    mkNumber 1 309 `shouldSatisfy` (> mkNumber 1 308)
    mkNumber 1 (-400) `shouldSatisfy` (> mkNumber 0 0)

  it "is exact for multipleOf" $ do
    (mkNumber 3 (-1) `isMultipleOf` mkNumber 1 (-4)) `shouldBe` True
    (mkNumber 21 (-4) `isMultipleOf` mkNumber 1 (-4)) `shouldBe` True
    (mkNumber 15 (-1) `isMultipleOf` mkNumber 1 0) `shouldBe` False
    (mkNumber 0 0 `isMultipleOf` mkNumber 7 0) `shouldBe` True

  it "orders like the rationals they denote" $
    property $ \a b c d ->
      let x = mkNumber a (c `mod` 20)
          y = mkNumber b (d `mod` 20)
          val m e = toRational m * 10 ^^ e
       in compare x y == compare (val a (c `mod` 20 :: Int)) (val b (d `mod` 20 :: Int))

  it "agrees with integer divisibility" $
    property $ \a (NonZero b) ->
      (mkNumber a 0 `isMultipleOf` mkNumber b 0) == (a `rem` b == 0)

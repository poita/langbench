module RandomSpec (spec) where

import Data.List (sort)
import Data.Word (Word64)
import Test.Hspec
import Test.QuickCheck hiding (shuffle)

import Spiremark.Random

takeWords :: Int -> Rng -> [Word64]
takeWords 0 _ = []
takeWords n g = let (w, g') = nextWord g in w : takeWords (n - 1) g'

spec :: Spec
spec = do
  it "reproduces the reference stream for seed 7" $
    takeWords 5 (mkRng 7) `shouldBe`
      [ 15130880334998875822, 17123930943180875438, 1648209070578717474
      , 1985375592982671918, 6908966637734145041 ]
  it "replaces seed 0 by the multiplier constant" $
    takeWords 3 (mkRng 0) `shouldBe` takeWords 3 (mkRng 0x2545F4914F6CDD1D)
  it "shuffles of length 0 or 1 consume no randomness" $ do
    snd (shuffle ([] :: [Int]) (mkRng 3)) `shouldBe` mkRng 3
    snd (shuffle [1 :: Int] (mkRng 3)) `shouldBe` mkRng 3
  it "matches the worked example of SPEC.md 26.12 for A's vault" $
    fst (shuffle [1 .. 8 :: Int] (mkRng 7)) `shouldBe` [6, 8, 5, 2, 4, 1, 3, 7]
  it "below n stays in range" $
    property $ \(Positive n) seed ->
      let (v, _) = below n (mkRng seed) in v >= 0 && v < n
  it "shuffle is a permutation" $
    property $ \xs seed ->
      sort (fst (shuffle (xs :: [Int]) (mkRng seed))) === sort xs

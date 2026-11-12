module Rubiks.CombinatoricsSpec (spec) where

import Data.List (permutations, sort, subsequences)
import Test.Hspec

import Rubiks.Internal.Combinatorics

spec :: Spec
spec = do
  it "computes binomial coefficients" $ do
    choose 12 4 `shouldBe` 495
    choose 8 4 `shouldBe` 70
    choose 3 5 `shouldBe` 0
    choose 5 0 `shouldBe` 1
  it "ranks every 4-subset of 12 exactly once, and unranks it" $ do
    let subsets = [s | s <- subsequences [0 .. 11], length s == 4]
    sort (map rankSubset subsets) `shouldBe` [0 .. 494]
    mapM_ (\s -> unrankSubset 12 4 (rankSubset s) `shouldBe` s) subsets
  it "ranks every permutation of 4 exactly once, and unranks it" $ do
    let ps = permutations [0 .. 3]
    sort (map rankPermutation ps) `shouldBe` [0 .. 23]
    mapM_ (\p -> unrankPermutation 4 (rankPermutation p) `shouldBe` p) ps
  it "computes permutation parity" $ do
    permutationParity [0, 1, 2, 3] `shouldBe` 0
    permutationParity [1, 0, 2, 3] `shouldBe` 1
    permutationParity [1, 2, 0, 3] `shouldBe` 0

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
-- | QuickCheck generators and numeric helpers shared by the test suite.
module Generators
  ( SmallMatrix (..)
  , Square (..)
  , Symmetric (..)
  , SPD (..)
  , Tall (..)
  , matrixOf
  , maxAbsDiff
  , approxMatrix
  , mulE
  ) where

import Test.QuickCheck

import qualified Linalg.Matrix as M
import Linalg.Matrix (Matrix)

-- | Entries drawn from small multiples of 1/4, so that products stay modest.
entry :: Gen Double
entry = (/ 4) . fromIntegral <$> choose (-24 :: Int, 24)

matrixOf :: Int -> Int -> Gen Matrix
matrixOf r c = M.fromList r c <$> vectorOf (r * c) entry

-- | Arbitrary matrix, 1..6 on each side.
newtype SmallMatrix = SmallMatrix Matrix deriving (Show)

instance Arbitrary SmallMatrix where
  arbitrary = do
    r <- choose (1, 6)
    c <- choose (1, 6)
    SmallMatrix <$> matrixOf r c

-- | Square matrix, order 1..6.
newtype Square = Square Matrix deriving (Show)

instance Arbitrary Square where
  arbitrary = do
    n <- choose (1, 6)
    Square <$> matrixOf n n

-- | Matrix with at least as many rows as columns.
newtype Tall = Tall Matrix deriving (Show)

instance Arbitrary Tall where
  arbitrary = do
    c <- choose (1, 5)
    r <- choose (c, 7)
    Tall <$> matrixOf r c

-- | Exactly symmetric matrix.
newtype Symmetric = Symmetric Matrix deriving (Show)

instance Arbitrary Symmetric where
  arbitrary = do
    Square a <- arbitrary
    pure (Symmetric (symmetrise a))

symmetrise :: Matrix -> Matrix
symmetrise a = M.generate n n (\i j -> M.unsafeAt a (min i j) (max i j))
  where
    n = M.rows a

-- | Symmetric positive definite matrix @B'B + I@.
newtype SPD = SPD Matrix deriving (Show)

instance Arbitrary SPD where
  arbitrary = do
    Square b <- arbitrary
    let g = mulE (M.transpose b) b
        n = M.rows b
    pure (SPD (symmetrise (M.generate n n (\i j -> M.unsafeAt g i j + if i == j then 1 else 0))))

-- | Largest absolute entrywise difference; infinite for differing shapes.
maxAbsDiff :: Matrix -> Matrix -> Double
maxAbsDiff a b
  | M.rows a /= M.rows b || M.cols a /= M.cols b = 1 / 0
  | otherwise = maximum (0 : zipWith (\x y -> abs (x - y)) (M.toList a) (M.toList b))

-- | Equal up to an absolute tolerance.
approxMatrix :: Double -> Matrix -> Matrix -> Bool
approxMatrix tol a b = maxAbsDiff a b <= tol

-- | Product of matrices whose shapes are known to agree.
mulE :: Matrix -> Matrix -> Matrix
mulE a b = either (error . show) id (M.mul a b)

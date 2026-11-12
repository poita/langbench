{-# LANGUAGE BangPatterns #-}
-- | Singular value decomposition by one-sided (Hestenes) Jacobi, and the
-- 2-norm condition number.
module Linalg.SVD
  ( SVD (..)
  , svd
  , singularValues
  , cond
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.ST (newArray)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.List (sortBy)
import Data.Ord (comparing, Down (..))

import Linalg.Error (LinalgError (..))
import Linalg.Internal (STU, forN, rd, wr)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M
import Linalg.SignConvention (normalizeColumnSigns)

-- | Thin SVD @A = U diag(s) V'@ of an @m x n@ matrix, @k = min m n@.
data SVD = SVD
  { svdU :: Matrix
    -- ^ @m x k@, orthonormal columns, sign-normalised.
  , svdS :: [Double]
    -- ^ The @k@ singular values, descending and non-negative.
  , svdV :: Matrix
    -- ^ @n x k@, orthonormal columns.
  }
  deriving (Eq, Show)

-- Result of the one-sided iteration on a tall matrix: singular values, the
-- normalised left vectors and right vectors, all in original column order.
data Raw = Raw (UArray Int Double) Matrix Matrix -- sigma, left (m' x n'), right (n' x n')

-- | One-sided Jacobi on a matrix with at least as many rows as columns.
jacobi :: Matrix -> Raw
jacobi a = runST $ do
  let m = M.rows a
      n = M.cols a
  -- W and V are held by columns: entry (i, j) lives at j*m+i resp. j*n+i.
  w <- newArray (0, m * n - 1) 0 :: ST s (STU s)
  forN 0 m $ \i -> forN 0 n $ \j -> wr w (j * m + i) (M.unsafeAt a i j)
  v <- newArray (0, n * n - 1) 0 :: ST s (STU s)
  forN 0 n $ \i -> wr v (i * n + i) 1
  let pairStep !p !q = do
        let go !i !al !be !ga
              | i >= m = pure (T3 al be ga)
              | otherwise = do
                  x <- rd w (p * m + i)
                  y <- rd w (q * m + i)
                  go (i + 1) (al + x * x) (be + y * y) (ga + x * y)
        T3 alpha beta gamma <- go 0 0 0 0
        if gamma == 0 || alpha == 0 || beta == 0 || abs gamma <= 1e-14 * sqrt (alpha * beta)
          then pure False
          else do
            let zeta = (beta - alpha) / (2 * gamma)
                t
                  | zeta >= 0 = 1 / (zeta + sqrt (zeta * zeta + 1))
                  | otherwise = -1 / (negate zeta + sqrt (zeta * zeta + 1))
                c = 1 / sqrt (t * t + 1)
                s = t * c
                rot arr len = forN 0 len $ \i -> do
                  x <- rd arr (p * len + i)
                  y <- rd arr (q * len + i)
                  wr arr (p * len + i) (c * x - s * y)
                  wr arr (q * len + i) (s * x + c * y)
            rot w m
            rot v n
            pure True
      sweep = goP 0 False
        where
          goP !p !acc
            | p >= n = pure acc
            | otherwise = goQ p (p + 1) acc >>= goP (p + 1)
          goQ !p !q !acc
            | q >= n = pure acc
            | otherwise = do
                r <- pairStep p q
                goQ p (q + 1) (acc || r)
      loop !k
        | k >= 60 = pure ()
        | otherwise = do
            rotated <- sweep
            if rotated then loop (k + 1) else pure ()
  loop (0 :: Int)
  sig <- mapM (\j -> norm w m j) [0 .. n - 1]
  wm <- M.unsafeFreezeMatrix n m w -- n x m: row j is column j of W
  vm <- M.unsafeFreezeMatrix n n v -- n x n: row j is column j of V
  let sigArr = listArray (0, n - 1) sig :: UArray Int Double
      left = M.generate m n $ \i j ->
        let sj = sigArr ! j in if sj == 0 then 0 else M.unsafeAt wm j i / sj
      right = M.generate n n $ \i j -> M.unsafeAt vm j i
  pure (Raw sigArr left right)
  where
    norm w m j = do
      let go !i !s
            | i >= m = pure s
            | otherwise = do
                x <- rd w (j * m + i)
                go (i + 1) (s + x * x)
      sqrt <$> go 0 0

data T3 = T3 !Double !Double !Double

-- Indices 0..n-1 ordered by descending sigma, ties by smaller index.
sortedOrder :: UArray Int Double -> Int -> [Int]
sortedOrder sig n = map snd (sortBy (comparing (Down . fst)) [(sig ! j, j) | j <- [0 .. n - 1]])

-- | Thin SVD. For @m < n@ the iteration runs on the transpose and the roles
-- of the two factors are swapped. Total: no error is possible.
svd :: Matrix -> SVD
svd a = SVD u' ss v'
  where
    m = M.rows a
    n = M.cols a
    k = min m n
    tall = m >= n
    Raw sig left right = jacobi (if tall then a else M.transpose a)
    order = sortedOrder sig k
    ordArr = listArray (0, k - 1) order :: UArray Int Int
    ss = [sig ! j | j <- order]
    pick mat = M.generate (M.rows mat) k (\i j -> M.unsafeAt mat i (ordArr ! j))
    (uRaw, vRaw) = if tall then (pick left, pick right) else (pick right, pick left)
    (u', flips) = normalizeColumnSigns uRaw
    flipArr = listArray (0, k - 1) flips :: UArray Int Bool
    v' = M.generate (M.rows vRaw) k $ \i j ->
      if flipArr ! j then negate (M.unsafeAt vRaw i j) else M.unsafeAt vRaw i j

-- | The singular values in descending order.
singularValues :: Matrix -> [Double]
singularValues = svdS . svd

-- | @sigma_max / sigma_min@. 'Singular' when the smallest singular value is
-- exactly zero.
cond :: Matrix -> Either LinalgError Double
cond a = case singularValues a of
  [] -> Left Singular
  ss@(smax : _)
    | last ss == 0 -> Left Singular
    | otherwise -> Right (smax / last ss)

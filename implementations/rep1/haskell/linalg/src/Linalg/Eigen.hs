{-# LANGUAGE BangPatterns #-}
-- | Symmetric eigendecomposition by the cyclic Jacobi method.
module Linalg.Eigen
  ( Eigen (..)
  , eigSym
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.ST (newArray)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Array.Unboxed (UArray, listArray, (!))

import Linalg.Error (LinalgError (..))
import Linalg.Internal (STU, forN, rd, wr)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M
import Linalg.SignConvention (normalizeColumnSigns)

-- | @A = V diag(w) V'@.
data Eigen = Eigen
  { eigenvalues :: [Double]
    -- ^ Ascending.
  , eigenvectors :: Matrix
    -- ^ Orthogonal; column @j@ is a unit eigenvector for @eigenvalues !! j@,
    -- sign-normalised (see "Linalg.SignConvention").
  }
  deriving (Eq, Show)

-- | Cyclic Jacobi eigendecomposition of a symmetric matrix.
--
-- Sweeps visit the pairs @(p, q)@, @p < q@, in row-major order and stop when
-- @off(M) <= 1e-14 * ||A||_F@, when @off@ stops decreasing, or after 60
-- sweeps. Errors: 'NotSquare', 'NotSymmetric'.
eigSym :: Matrix -> Either LinalgError Eigen
eigSym a
  | not (M.isSquare a) = Left NotSquare
  | not (M.isSymmetric a) = Left NotSymmetric
  | otherwise = Right $ runST $ do
      let n = M.rows a
          phi = M.normFrobenius a
      m <- M.thawMatrix a
      v <- newArray (0, n * n - 1) 0 :: ST s (STU s)
      forN 0 n $ \i -> wr v (i * n + i) 1
      let off = do
            let goI !i !s
                  | i >= n = pure s
                  | otherwise = do
                      let goJ !j !t
                            | j >= n = pure t
                            | otherwise = do
                                x <- rd m (i * n + j)
                                goJ (j + 1) (t + x * x)
                      s' <- goJ (i + 1) s
                      goI (i + 1) s'
            sqrt . (2 *) <$> goI 0 0
          rotate !p !q = do
            mpq <- rd m (p * n + q)
            if mpq == 0
              then pure ()
              else do
                mpp <- rd m (p * n + p)
                mqq <- rd m (q * n + q)
                let theta = (mqq - mpp) / (2 * mpq)
                    t
                      | theta >= 0 = 1 / (theta + sqrt (theta * theta + 1))
                      | otherwise = -1 / (negate theta + sqrt (theta * theta + 1))
                    c = 1 / sqrt (t * t + 1)
                    s = t * c
                    cols' arr = forN 0 n $ \i -> do
                      x <- rd arr (i * n + p)
                      y <- rd arr (i * n + q)
                      wr arr (i * n + p) (c * x - s * y)
                      wr arr (i * n + q) (s * x + c * y)
                forN 0 n $ \i -> do
                  x <- rd m (i * n + p)
                  y <- rd m (i * n + q)
                  wr m (i * n + p) (c * x - s * y)
                  wr m (i * n + q) (s * x + c * y)
                forN 0 n $ \j -> do
                  x <- rd m (p * n + j)
                  y <- rd m (q * n + j)
                  wr m (p * n + j) (c * x - s * y)
                  wr m (q * n + j) (s * x + c * y)
                wr m (p * n + q) 0
                wr m (q * n + p) 0
                cols' v
          sweep = forN 0 n $ \p -> forN (p + 1) n $ \q -> rotate p q
          loop !k !prev
            | k >= 60 = pure ()
            | otherwise = do
                o <- off
                if o <= 1e-14 * phi || o >= prev
                  then pure ()
                  else sweep >> loop (k + 1) o
      loop (0 :: Int) (1 / 0)
      ws <- mapM (\i -> rd m (i * n + i)) [0 .. n - 1]
      vm <- M.unsafeFreezeMatrix n n v
      let order = map snd (sortBy (comparing fst) (zip ws [0 :: Int ..]))
          wsArr = listArray (0, n - 1) ws :: UArray Int Double
          orderArr = listArray (0, n - 1) order :: UArray Int Int
          sorted = M.generate n n (\i j -> M.unsafeAt vm i (orderArr ! j))
      pure (Eigen [wsArr ! i | i <- order] (fst (normalizeColumnSigns sorted)))

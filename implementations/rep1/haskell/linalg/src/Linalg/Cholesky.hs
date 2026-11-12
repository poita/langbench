{-# LANGUAGE BangPatterns #-}
-- | Cholesky factorisation of symmetric positive definite matrices.
module Linalg.Cholesky
  ( cholesky
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.ST (newArray)

import Linalg.Error (LinalgError (..))
import Linalg.Internal (STU, forN, rd, wr)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M

-- | @cholesky a@ is the lower triangular @L@ with a positive diagonal such
-- that @A = L L'@, computed column by column.
--
-- Errors, in the order they are checked: 'NotSquare', 'NotSymmetric'
-- (exact comparison), 'NotPositiveDefinite' (a pivot @s <= 0@).
cholesky :: Matrix -> Either LinalgError Matrix
cholesky a
  | not (M.isSquare a) = Left NotSquare
  | not (M.isSymmetric a) = Left NotSymmetric
  | otherwise = runST $ do
      let n = M.rows a
      l <- newArray (0, n * n - 1) 0 :: ST s (STU s)
      let dotRows !i !j = go 0 0
            where
              go !k !s
                | k >= j = pure s
                | otherwise = do
                    x <- rd l (i * n + k)
                    y <- rd l (j * n + k)
                    go (k + 1) (s + x * y)
          column !j
            | j >= n = pure True
            | otherwise = do
                sm <- dotRows j j
                let s = M.unsafeAt a j j - sm
                if s <= 0
                  then pure False
                  else do
                    let !ljj = sqrt s
                    wr l (j * n + j) ljj
                    forN (j + 1) n $ \i -> do
                      t <- dotRows i j
                      wr l (i * n + j) ((M.unsafeAt a i j - t) / ljj)
                    column (j + 1)
      ok <- column 0
      if ok then Right <$> M.unsafeFreezeMatrix n n l else pure (Left NotPositiveDefinite)

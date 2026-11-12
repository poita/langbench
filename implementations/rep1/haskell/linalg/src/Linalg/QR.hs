{-# LANGUAGE BangPatterns #-}
-- | Householder QR factorisation and least squares.
module Linalg.QR
  ( QR (..)
  , qr
  , lstsq
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.ST (newArray)

import Linalg.Error (LinalgError (..))
import Linalg.Internal (STU, forDown, forN, rd, wr)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M

-- | A thin factorisation @A = Q R@ of an @m x n@ matrix with @m >= n@.
data QR = QR
  { qrQ :: Matrix
    -- ^ @m x n@ with orthonormal columns.
  , qrR :: Matrix
    -- ^ @n x n@ upper triangular with a non-negative diagonal.
  }
  deriving (Eq, Show)

-- | Thin Householder QR. Reflectors are applied to @R@ in increasing column
-- order, @Q@ is formed by applying them in reverse to the first @n@ columns
-- of the identity, and finally the signs are fixed so that @diag R >= 0@.
--
-- 'DimensionMismatch' when @m < n@. Rank-deficient input is accepted: a zero
-- column simply yields an identity reflector.
qr :: Matrix -> Either LinalgError QR
qr a
  | m < n = Left DimensionMismatch
  | otherwise = Right $ runST $ do
      r <- M.thawMatrix a -- m x n
      vs <- newArray (0, m * n - 1) 0 :: ST s (STU s) -- column k holds reflector k in rows k..m-1
      active <- newArray (0, n - 1) 0 :: ST s (STU s) -- 1.0 when reflector k is not the identity
      d <- newArray (0, n - 1) 0 :: ST s (STU s)
      forN 0 n $ \k -> do
        let sumSq !i !s
              | i >= m = pure s
              | otherwise = do
                  x <- rd r (i * n + k)
                  sumSq (i + 1) (s + x * x)
        nu2 <- sumSq k 0
        let nu = sqrt nu2
        if nu == 0
          then forN (k + 1) m $ \i -> wr r (i * n + k) 0
          else do
            rkk <- rd r (k * n + k)
            let alpha = if rkk >= 0 then negate nu else nu
            forN k m $ \i -> do
              x <- rd r (i * n + k)
              wr vs (i * n + k) (if i == k then x - alpha else x)
            let vsq !i !s
                  | i >= m = pure s
                  | otherwise = do
                      x <- rd vs (i * n + k)
                      vsq (i + 1) (s + x * x)
            vn <- sqrt <$> vsq k 0
            forN k m $ \i -> do
              x <- rd vs (i * n + k)
              wr vs (i * n + k) (x / vn)
            reflect r m n k (k + 1) vs d
            wr r (k * n + k) alpha
            forN (k + 1) m $ \i -> wr r (i * n + k) 0
            wr active k 1
      q <- newArray (0, m * n - 1) 0 :: ST s (STU s)
      forN 0 n $ \i -> wr q (i * n + i) 1
      forDown (n - 1) 0 $ \k -> do
        act <- rd active k
        if act == 0 then pure () else reflect q m n k k vs d
      -- sign normalisation
      forN 0 n $ \j -> do
        rjj <- rd r (j * n + j)
        if rjj < 0
          then do
            forN j n $ \c -> rd r (j * n + c) >>= wr r (j * n + c) . negate
            forN 0 m $ \i -> rd q (i * n + j) >>= wr q (i * n + j) . negate
          else pure ()
      qm <- M.unsafeFreezeMatrix m n q
      rm <- M.unsafeFreezeMatrix m n r
      pure (QR qm (M.generate n n (\i j -> if j >= i then M.unsafeAt rm i j else 0)))
  where
    m = M.rows a
    n = M.cols a

-- | @reflect t m n k c0 vs d@ applies reflector @k@ (stored in column @k@ of
-- @vs@, rows @k..m-1@) to columns @c0..n-1@ of the @m x n@ row-major matrix
-- @t@: @t[k.., j] -= 2 (v' t[k.., j]) v@. @d@ is scratch space of length @n@.
reflect :: STU s -> Int -> Int -> Int -> Int -> STU s -> STU s -> ST s ()
reflect t m n k c0 vs d = do
  forN c0 n $ \j -> wr d j 0
  forN k m $ \i -> do
    vi <- rd vs (i * n + k)
    forN c0 n $ \j -> do
      s <- rd d j
      x <- rd t (i * n + j)
      wr d j (s + vi * x)
  forN k m $ \i -> do
    vi <- rd vs (i * n + k)
    forN c0 n $ \j -> do
      dj <- rd d j
      x <- rd t (i * n + j)
      wr t (i * n + j) (x - 2 * dj * vi)

-- | Least squares @min ||A X - B||_F@ for @A@ of shape @m x n@, @m >= n@, via
-- @R X = Q' B@. 'DimensionMismatch' if @m < n@ or @B@ has the wrong number of
-- rows; 'Singular' when @R@ has an exactly zero diagonal entry.
lstsq :: Matrix -> Matrix -> Either LinalgError Matrix
lstsq a b
  | M.rows a < M.cols a = Left DimensionMismatch
  | M.rows b /= M.rows a = Left DimensionMismatch
  | otherwise = do
      QR q r <- qr a
      let n = M.cols a
          m = M.rows a
          k = M.cols b
      if any (\i -> M.unsafeAt r i i == 0) [0 .. n - 1]
        then Left Singular
        else Right $ runST $ do
          x <- newArray (0, n * k - 1) 0 :: ST s (STU s)
          y <- newArray (0, n - 1) 0 :: ST s (STU s)
          forN 0 k $ \c -> do
            forN 0 n $ \i -> do
              let go !l !s
                    | l >= m = s
                    | otherwise = go (l + 1) (s + M.unsafeAt q l i * M.unsafeAt b l c)
              wr y i (go 0 0)
            forDown (n - 1) 0 $ \i -> do
              s0 <- rd y i
              let go !j !s
                    | j >= n = pure s
                    | otherwise = do
                        xj <- rd y j
                        go (j + 1) (s - M.unsafeAt r i j * xj)
              s <- go (i + 1) s0
              wr y i (s / M.unsafeAt r i i)
            forN 0 n $ \i -> rd y i >>= wr x (i * k + c)
          M.unsafeFreezeMatrix n k x

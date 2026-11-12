{-# LANGUAGE BangPatterns #-}
-- | LU factorisation with partial pivoting and its users: determinant,
-- linear solves and inverse.
--
-- The elimination is the right-looking Gaussian elimination of the
-- specification: the pivot of column @k@ is the entry of largest magnitude in
-- rows @k..n-1@ (smallest row index on ties), and a pivot of exactly @0.0@
-- means the matrix is singular.
module Linalg.LU
  ( LU
  , luSize
  , luFactor
  , luPermutation
  , luSwaps
  , luP
  , luL
  , luU
  , luSolve
    -- * One-shot functions
  , lu
  , det
  , solve
  , inverse
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeAt, unsafeFreeze, unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, newListArray)
import Data.Array.Unboxed (UArray, elems)
import qualified Data.Array.Unboxed as U

import Linalg.Error (LinalgError (..))
import Linalg.Internal (STU, forN, rd, wr)
import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M

-- | A computed factorisation @P A = L U@ of a square matrix.
data LU = LU
  { luSize :: !Int
    -- ^ The order @n@ of the factored matrix.
  , luPerm :: !(UArray Int Int)
  , luSwaps :: !Int
    -- ^ Number of row interchanges performed (determines the sign of the
    -- determinant).
  , luCompact :: !Matrix
    -- ^ @L@ strictly below the diagonal, @U@ on and above it.
  }

-- | @luPermutation f !! i@ is the index in the original matrix of the row now
-- sitting in row @i@.
luPermutation :: LU -> [Int]
luPermutation = elems . luPerm

-- | The permutation matrix @P@ with @P[i][perm[i]] = 1@.
luP :: LU -> Matrix
luP f = M.generate n n (\i j -> if luPerm f U.! i == j then 1 else 0)
  where
    n = luSize f

-- | The unit lower triangular factor.
luL :: LU -> Matrix
luL f = M.generate n n entry
  where
    n = luSize f
    entry i j
      | i == j = 1
      | i > j = M.unsafeAt (luCompact f) i j
      | otherwise = 0

-- | The upper triangular factor.
luU :: LU -> Matrix
luU f = M.generate n n (\i j -> if j >= i then M.unsafeAt (luCompact f) i j else 0)
  where
    n = luSize f

-- | Factor a square matrix. 'NotSquare' for a non-square input, 'Singular'
-- when a pivot is exactly zero.
luFactor :: Matrix -> Either LinalgError LU
luFactor a
  | not (M.isSquare a) = Left NotSquare
  | otherwise = runST $ do
      let n = M.rows a
      m <- M.thawMatrix a
      perm <- newListArray (0, n - 1) [0 .. n - 1] :: ST s (STUArray s Int Int)
      let findPivot !k = go (k + 1) k . abs =<< rd m (k * n + k)
            where
              go !i !best !bv
                | i >= n = pure (best, bv)
                | otherwise = do
                    v <- abs <$> rd m (i * n + k)
                    if v > bv then go (i + 1) i v else go (i + 1) best bv
          swapRows !p !k = do
            forN 0 n $ \j -> do
              x <- rd m (p * n + j)
              y <- rd m (k * n + j)
              wr m (p * n + j) y
              wr m (k * n + j) x
            x <- unsafeRead perm p
            y <- unsafeRead perm k
            unsafeWrite perm p y
            unsafeWrite perm k x
          step !k !swaps
            | k >= n = pure (Just swaps)
            | otherwise = do
                (p, bv) <- findPivot k
                if bv == 0
                  then pure Nothing
                  else do
                    if p /= k then swapRows p k else pure ()
                    piv <- rd m (k * n + k)
                    forN (k + 1) n $ \i -> do
                      x <- rd m (i * n + k)
                      let !f = x / piv
                      wr m (i * n + k) f
                      forN (k + 1) n $ \j -> do
                        mij <- rd m (i * n + j)
                        mkj <- rd m (k * n + j)
                        wr m (i * n + j) (mij - f * mkj)
                    step (k + 1) (if p /= k then swaps + 1 else swaps)
      res <- step 0 (0 :: Int)
      case res of
        Nothing -> pure (Left Singular)
        Just swaps -> do
          compact <- M.unsafeFreezeMatrix n n m
          p <- unsafeFreeze perm
          pure (Right (LU n p swaps compact))

-- | Solve @A X = B@ given the factorisation of @A@, one column of @B@ at a
-- time: permute, forward substitution through @L@, back substitution through
-- @U@. @B@ must have @luSize@ rows.
luSolve :: LU -> Matrix -> Matrix
luSolve (LU n perm _ lu') b = runST $ do
  let k = M.cols b
  x <- newArray (0, max 0 (n * k - 1)) 0 :: ST s (STU s)
  col <- newArray (0, max 0 (n - 1)) 0 :: ST s (STU s)
  forN 0 k $ \c -> do
    forN 0 n $ \i -> wr col i (M.unsafeAt b (unsafeAt perm i) c)
    -- forward substitution, L has unit diagonal
    forN 0 n $ \i -> do
      s0 <- rd col i
      let go !j !s
            | j >= i = pure s
            | otherwise = do
                y <- rd col j
                go (j + 1) (s - M.unsafeAt lu' i j * y)
      s <- go 0 s0
      wr col i s
    -- back substitution
    let back !i
          | i < 0 = pure ()
          | otherwise = do
              s0 <- rd col i
              let go !j !s
                    | j >= n = pure s
                    | otherwise = do
                        y <- rd col j
                        go (j + 1) (s - M.unsafeAt lu' i j * y)
              s <- go (i + 1) s0
              wr col i (s / M.unsafeAt lu' i i)
              back (i - 1)
    back (n - 1)
    forN 0 n $ \i -> rd col i >>= wr x (i * k + c)
  M.unsafeFreezeMatrix n k x

-- | @lu a@ returns @(P, L, U)@ with @P A = L U@.
lu :: Matrix -> Either LinalgError (Matrix, Matrix, Matrix)
lu a = (\f -> (luP f, luL f, luU f)) <$> luFactor a

-- | Determinant. A zero pivot gives @0.0@ rather than an error; otherwise the
-- product of @U@'s diagonal (increasing order) times @(-1)^swaps@.
det :: Matrix -> Either LinalgError Double
det a = case luFactor a of
  Left Singular -> Right 0
  Left e -> Left e
  Right f ->
    let n = luSize f
        go !i !p
          | i >= n = p
          | otherwise = go (i + 1) (p * M.unsafeAt (luCompact f) i i)
        d = go 1 (M.unsafeAt (luCompact f) 0 0)
     in Right (if odd (luSwaps f) then negate d else d)

-- | Solve @A X = B@. Checks that @A@ is square before comparing @B@'s row
-- count.
solve :: Matrix -> Matrix -> Either LinalgError Matrix
solve a b
  | not (M.isSquare a) = Left NotSquare
  | M.rows b /= M.rows a = Left DimensionMismatch
  | otherwise = (`luSolve` b) <$> luFactor a

-- | The inverse, computed as @solve A I@.
inverse :: Matrix -> Either LinalgError Matrix
inverse a
  | not (M.isSquare a) = Left NotSquare
  | otherwise = (`luSolve` M.identity (M.rows a)) <$> luFactor a

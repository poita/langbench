{-# LANGUAGE BangPatterns #-}
-- | A dense, row-major matrix of 'Double's together with the elementwise
-- operations, product, transpose and norms.
--
-- All sums are single running sums in increasing index order (no pairwise or
-- compensated summation), so results are reproducible bit for bit.
module Linalg.Matrix
  ( Matrix
    -- * Construction and inspection
  , rows
  , cols
  , fromList
  , fromLists
  , toList
  , toLists
  , generate
  , zeros
  , identity
  , (!)
  , unsafeAt
  , row
  , column
  , isSquare
  , isSymmetric
    -- * Arithmetic
  , add
  , mul
  , transpose
    -- * Norms
  , norm1
  , normInf
  , normFrobenius
    -- * Interoperation with mutable arrays
  , thawMatrix
  , unsafeFreezeMatrix
  ) where

import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeFreeze, unsafeRead, unsafeWrite)
import qualified Data.Array.Base as A
import Data.Array.ST (STUArray, newArray)
import Data.Array.Unboxed (UArray, listArray)

import Linalg.Error (LinalgError (..))
import Linalg.Internal (forN)

-- | A dense @rows x cols@ matrix, stored row-major. Both dimensions are
-- at least 1 for matrices built with the smart constructors.
data Matrix = Matrix !Int !Int !(UArray Int Double)
  deriving (Eq)

instance Show Matrix where
  showsPrec d m = showParen (d > 10) (showString "fromLists " . shows (toLists m))

-- | Number of rows.
rows :: Matrix -> Int
rows (Matrix r _ _) = r

-- | Number of columns.
cols :: Matrix -> Int
cols (Matrix _ c _) = c

-- | @fromList r c xs@ builds an @r x c@ matrix from @r*c@ entries given in
-- row-major order. Calls 'error' if the length is wrong.
fromList :: Int -> Int -> [Double] -> Matrix
fromList r c xs
  | r < 0 || c < 0 = error "Linalg.Matrix.fromList: negative dimension"
  | length xs /= r * c = error "Linalg.Matrix.fromList: wrong number of entries"
  | otherwise = Matrix r c (listArray (0, r * c - 1) xs)

-- | Build a matrix from a non-empty list of equally long rows.
fromLists :: [[Double]] -> Matrix
fromLists [] = error "Linalg.Matrix.fromLists: no rows"
fromLists xss@(x : _)
  | any ((/= c) . length) xss = error "Linalg.Matrix.fromLists: ragged rows"
  | otherwise = fromList (length xss) c (concat xss)
  where
    c = length x

-- | All entries in row-major order.
toList :: Matrix -> [Double]
toList (Matrix r c a) = [A.unsafeAt a i | i <- [0 .. r * c - 1]]

-- | The matrix as a list of rows.
toLists :: Matrix -> [[Double]]
toLists m = [row m i | i <- [0 .. rows m - 1]]

-- | @generate r c f@ is the matrix whose @(i, j)@ entry is @f i j@
-- (0-based).
generate :: Int -> Int -> (Int -> Int -> Double) -> Matrix
generate r c f =
  Matrix r c (listArray (0, r * c - 1) [f i j | i <- [0 .. r - 1], j <- [0 .. c - 1]])

-- | The @r x c@ zero matrix.
zeros :: Int -> Int -> Matrix
zeros r c = generate r c (\_ _ -> 0)

-- | The @n x n@ identity matrix.
identity :: Int -> Matrix
identity n = generate n n (\i j -> if i == j then 1 else 0)

infixl 9 !

-- | Bounds-checked 0-based indexing: @m ! (i, j)@.
(!) :: Matrix -> (Int, Int) -> Double
m@(Matrix r c _) ! (i, j)
  | i < 0 || i >= r || j < 0 || j >= c = error "Linalg.Matrix.(!): index out of range"
  | otherwise = unsafeAt m i j

-- | Unchecked indexing: @unsafeAt m i j@.
unsafeAt :: Matrix -> Int -> Int -> Double
unsafeAt (Matrix _ c a) i j = A.unsafeAt a (i * c + j)
{-# INLINE unsafeAt #-}

-- | Row @i@ as a list.
row :: Matrix -> Int -> [Double]
row m i = [unsafeAt m i j | j <- [0 .. cols m - 1]]

-- | Column @j@ as a list.
column :: Matrix -> Int -> [Double]
column m j = [unsafeAt m i j | i <- [0 .. rows m - 1]]

-- | Is the matrix square?
isSquare :: Matrix -> Bool
isSquare m = rows m == cols m

-- | Is the matrix square with @A[i][j] == A[j][i]@ (exact comparison)?
isSymmetric :: Matrix -> Bool
isSymmetric m@(Matrix n c _) =
  n == c && and [unsafeAt m i j == unsafeAt m j i | i <- [0 .. n - 1], j <- [0 .. i - 1]]

-- | A fresh mutable copy of the entries (row-major, index @i*cols + j@).
thawMatrix :: Matrix -> ST s (STUArray s Int Double)
thawMatrix (Matrix r c a) = do
  arr <- newArray (0, max 0 (r * c - 1)) 0
  forN 0 (r * c) $ \i -> unsafeWrite arr i (A.unsafeAt a i)
  pure arr

-- | @unsafeFreezeMatrix r c arr@ wraps a mutable row-major array of at least
-- @r*c@ entries as a matrix without copying. The caller must not use @arr@
-- afterwards.
unsafeFreezeMatrix :: Int -> Int -> STUArray s Int Double -> ST s Matrix
unsafeFreezeMatrix r c arr = do
  a <- unsafeFreeze arr
  pure (Matrix r c a)

-- | Elementwise sum; 'DimensionMismatch' unless the shapes agree.
add :: Matrix -> Matrix -> Either LinalgError Matrix
add (Matrix r c a) (Matrix r' c' b)
  | r /= r' || c /= c' = Left DimensionMismatch
  | otherwise = Right (Matrix r c (listArray (0, r * c - 1) [A.unsafeAt a i + A.unsafeAt b i | i <- [0 .. r * c - 1]]))

-- | Matrix product. @C[i][j] = sum_k A[i][k] B[k][j]@ accumulated in one
-- running sum over increasing @k@. 'DimensionMismatch' unless
-- @cols A == rows B@.
mul :: Matrix -> Matrix -> Either LinalgError Matrix
mul (Matrix m k a) (Matrix k' n b)
  | k /= k' = Left DimensionMismatch
  | otherwise = Right $ runST $ do
      c <- newArray (0, max 0 (m * n - 1)) 0 :: ST s (STUArray s Int Double)
      forN 0 m $ \i ->
        forN 0 k $ \l -> do
          let !x = A.unsafeAt a (i * k + l)
          forN 0 n $ \j -> do
            s <- unsafeRead c (i * n + j)
            unsafeWrite c (i * n + j) (s + x * A.unsafeAt b (l * n + j))
      unsafeFreezeMatrix m n c

-- | The transpose.
transpose :: Matrix -> Matrix
transpose m@(Matrix r c _) = generate c r (\i j -> unsafeAt m j i)

-- | Maximum absolute column sum (each column summed over increasing row).
norm1 :: Matrix -> Double
norm1 m@(Matrix r c _) = foldl' max 0 [colSum j | j <- [0 .. c - 1]]
  where
    colSum j = go 0 0
      where
        go !i !s
          | i >= r = s
          | otherwise = go (i + 1) (s + abs (unsafeAt m i j))

-- | Maximum absolute row sum (each row summed over increasing column).
normInf :: Matrix -> Double
normInf m@(Matrix r c _) = foldl' max 0 [rowSum i | i <- [0 .. r - 1]]
  where
    rowSum i = go 0 0
      where
        go !j !s
          | j >= c = s
          | otherwise = go (j + 1) (s + abs (unsafeAt m i j))

-- | Frobenius norm: the square root of the sum of squares, summed in
-- row-major order.
normFrobenius :: Matrix -> Double
normFrobenius (Matrix r c a) = sqrt (go 0 0)
  where
    n = r * c
    go !i !s
      | i >= n = s
      | otherwise = let !x = A.unsafeAt a i in go (i + 1) (s + x * x)

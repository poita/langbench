{-# LANGUAGE BangPatterns #-}
-- | The sign convention used to make eigenvectors and singular vectors
-- unique.
module Linalg.SignConvention
  ( normalizeColumnSigns
  ) where

import Data.Array.Unboxed (UArray, listArray, (!))

import Linalg.Matrix (Matrix)
import qualified Linalg.Matrix as M

-- | For each column take the smallest row index @i*@ attaining
-- @max_i |v[i]|@; if @v[i*] < 0@ negate the column. All-zero columns are left
-- alone. Returns the normalised matrix and, per column, whether it was
-- negated.
normalizeColumnSigns :: Matrix -> (Matrix, [Bool])
normalizeColumnSigns a = (M.generate (M.rows a) (M.cols a) entry, flips)
  where
    flips = map flipped [0 .. M.cols a - 1]
    flipped j = pivot (M.column a j) < 0
    pivot = go 0 0
      where
        go _ best [] = best
        go !m best (x : xs)
          | abs x > m = go (abs x) x xs
          | otherwise = go m best xs
    flipArr = listArray (0, M.cols a - 1) flips :: UArray Int Bool
    entry i j = if flipArr ! j then negate (M.unsafeAt a i j) else M.unsafeAt a i j

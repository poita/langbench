-- |
-- Module      : Diff.Intern
-- Description : Map elements to dense integer ids so comparison is O(1).
module Diff.Intern
  ( internPair
  ) where

import           Data.Array.Unboxed (UArray, listArray)
import qualified Data.Map.Strict    as M

-- | Intern two sequences against a shared table: equal elements receive equal
-- ids and different elements different ids.  Both results are 0-indexed
-- arrays of the same length as the corresponding input.
--
-- Expected time O(L log K) for total input size L and K distinct elements.
internPair :: Ord a => [a] -> [a] -> (UArray Int Int, UArray Int Int)
internPair xs ys = (toArr n xids, toArr m yids)
  where
    (m1, xids) = go M.empty xs
    (_, yids)  = go m1 ys
    n = length xids
    m = length yids
    toArr len = listArray (0, len - 1)

    go tbl = loop tbl []
      where
        loop t acc []       = (t, reverse acc)
        loop t acc (z : zs) =
          case M.lookup z t of
            Just i  -> i `seq` loop t (i : acc) zs
            Nothing -> let i = M.size t
                       in loop (M.insert z i t) (i : acc) zs

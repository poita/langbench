-- |
-- Module      : Rubiks.Internal.Table
-- Description : Breadth-first distance tables over coordinate spaces.
module Rubiks.Internal.Table
  ( DistanceTable
  , unreached
  , distanceTable
  ) where

import Control.Monad.ST (ST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray, runSTUArray)
import Data.Array.Unboxed (UArray)
import Data.Word (Word8)

-- | Distance from each coordinate value to the goal, or 'unreached'.
type DistanceTable = UArray Int Word8

-- | Marks coordinate values that cannot reach the goal.
unreached :: Word8
unreached = 255

-- | @distanceTable size goal nMoves step@ fills, by breadth-first search from
-- @goal@, the number of moves needed to reach @goal@ from every value in
-- @[0, size)@.  @step s i@ is the value after applying the @i@-th of @nMoves@
-- moves to value @s@.  The move set must be closed under inverses, so that
-- distance to the goal equals distance from it.
distanceTable :: Int -> Int -> Int -> (Int -> Int -> Int) -> DistanceTable
distanceTable size goal nMoves step = runSTUArray $ do
  dist <- newArray (0, size - 1) unreached
  queue <- newArray (0, size - 1) 0 :: ST s (STUArray s Int Int)
  unsafeWrite dist goal 0
  unsafeWrite queue 0 goal
  let loop !hd !tl
        | hd >= tl = pure ()
        | otherwise = do
            s <- unsafeRead queue hd
            d <- unsafeRead dist s
            tl' <- expand s (d + 1) 0 tl
            loop (hd + 1) tl'
      expand !s !d' !i !tl
        | i >= nMoves = pure tl
        | otherwise = do
            let t = step s i
            old <- unsafeRead dist t
            if old == unreached
              then do
                unsafeWrite dist t d'
                unsafeWrite queue tl t
                expand s d' (i + 1) (tl + 1)
              else expand s d' (i + 1) tl
  loop 0 1
  pure dist

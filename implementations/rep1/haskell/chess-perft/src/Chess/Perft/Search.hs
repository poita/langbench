-- |
-- Module      : Chess.Perft.Search
-- Description : Perft and divide over the legal move generator.
module Chess.Perft.Search
  ( perft
  , divide
  ) where

import Data.List (sortOn)

import Chess.Perft.MoveGen
import Chess.Perft.Position
import Chess.Perft.Types

-- | @perft depth pos@ is the number of leaf nodes reached by playing every
-- sequence of @depth@ legal moves from @pos@. @perft 0 pos == 1@; a
-- position without legal moves (checkmate or stalemate) has @perft d == 0@
-- for @d >= 1@. Negative depths are treated as 0.
--
-- The whole tree is walked depth-first; at depth 1 the legal moves are
-- counted rather than played.
perft :: Int -> Position -> Int
perft depth pos
  | depth <= 0 = 1
  | depth == 1 = countLegalMoves pos
  | otherwise =
      foldl' (\ !acc m -> acc + perft (depth - 1) (makeMove pos m)) 0 (legalMoves pos)

-- | @divide depth pos@ lists every legal move with @perft (depth - 1)@ of
-- the position after it, sorted by the move's UCI string (ASCII order).
-- The counts sum to @perft depth pos@ (for @depth >= 1@).
divide :: Int -> Position -> [(Move, Int)]
divide depth pos =
  sortOn (moveToUci . fst)
    [(m, perft (depth - 1) (makeMove pos m)) | m <- legalMoves pos]

-- |
-- Module      : Chess.Perft
-- Description : Legal chess move generation with perft and divide.
--
-- A minimal session:
--
-- >>> import Chess.Perft
-- >>> let Right pos = parseFen "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
-- >>> perft 3 pos
-- 8902
-- >>> map moveToUci (take 3 (legalMoves pos)) -- order unspecified
-- ["a2a3","a2a4","b1a3"]
-- >>> [ (moveToUci m, n) | (m, n) <- divide 2 pos ] !! 0
-- ("a2a3",20)
--
-- This module re-exports the public API:
--
-- * "Chess.Perft.Types": colours, pieces, squares, moves and UCI notation;
-- * "Chess.Perft.Position": FEN parsing and printing, 'makeMove', attack tests;
-- * "Chess.Perft.MoveGen": legal move generation;
-- * "Chess.Perft.Search": 'perft' and 'divide';
-- * "Chess.Perft.Query": the textual query format of the CLI.
--
-- "Chess.Perft.Bitboard" (bitboards and attack tables) is available
-- separately for lower-level use.
module Chess.Perft
  ( module Chess.Perft.Types
  , module Chess.Perft.Position
  , module Chess.Perft.MoveGen
  , module Chess.Perft.Search
  , module Chess.Perft.Query
  ) where

import Chess.Perft.MoveGen
import Chess.Perft.Position
import Chess.Perft.Query
import Chess.Perft.Search
import Chess.Perft.Types

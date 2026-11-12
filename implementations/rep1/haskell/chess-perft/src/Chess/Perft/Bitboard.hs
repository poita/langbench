-- |
-- Module      : Chess.Perft.Bitboard
-- Description : 64-bit sets of squares and precomputed attack tables.
--
-- A 'Bitboard' has bit @n@ set when square @n@ is a member. Attack tables
-- are built once (as top-level constants) from first principles; slider
-- attacks use the classical "ray and first blocker" technique.
module Chess.Perft.Bitboard
  ( Bitboard
  , squareBB
  , lowestSquare
  , foldBits
  , bitsToList
  , allSquares
    -- * Attack sets
  , knightAttacks
  , kingAttacks
  , pawnAttacks
  , bishopAttacks
  , rookAttacks
  , queenAttacks
    -- * Geometry
  , between
  , line
  ) where

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits (complement, countLeadingZeros, countTrailingZeros, shiftL, xor, (.&.), (.|.))
import Data.Word (Word64)

import Chess.Perft.Types

-- | A set of squares.
type Bitboard = Word64

-- | The singleton set containing one square.
squareBB :: Square -> Bitboard
squareBB sq = 1 `shiftL` sq
{-# INLINE squareBB #-}

-- | The least square in a non-empty set.
lowestSquare :: Bitboard -> Square
lowestSquare = countTrailingZeros
{-# INLINE lowestSquare #-}

-- | Strict left fold over the squares of a set, in ascending order.
foldBits :: (a -> Square -> a) -> a -> Bitboard -> a
foldBits f = go
  where
    go !acc 0 = acc
    go !acc bb =
      let sq = countTrailingZeros bb
       in go (f acc sq) (bb .&. (bb - 1))
{-# INLINE foldBits #-}

-- | The squares of a set in ascending order.
bitsToList :: Bitboard -> [Square]
bitsToList bb
  | bb == 0 = []
  | otherwise = countTrailingZeros bb : bitsToList (bb .&. (bb - 1))

-- | The set of all 64 squares.
allSquares :: Bitboard
allSquares = complement 0

------------------------------------------------------------------------
-- Leaper tables

-- Squares reached from @sq@ by the given (file, rank) offsets, staying on
-- the board.
stepsFrom :: [(Int, Int)] -> Square -> Bitboard
stepsFrom deltas sq =
  foldl' (.|.) 0
    [ squareBB (mkSquare f r)
    | (df, dr) <- deltas
    , let f = fileOf sq + df
    , let r = rankOf sq + dr
    , f >= 0, f < 8, r >= 0, r < 8 ]

table :: (Square -> Bitboard) -> UArray Int Word64
table f = listArray (0, 63) (map f [0 .. 63])

knightTable, kingTable, whitePawnTable, blackPawnTable :: UArray Int Word64
knightTable = table $ stepsFrom
  [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
kingTable = table $ stepsFrom
  [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
whitePawnTable = table $ stepsFrom [(-1, 1), (1, 1)]
blackPawnTable = table $ stepsFrom [(-1, -1), (1, -1)]
{-# NOINLINE knightTable #-}
{-# NOINLINE kingTable #-}
{-# NOINLINE whitePawnTable #-}
{-# NOINLINE blackPawnTable #-}

-- | Squares a knight on the given square attacks.
knightAttacks :: Square -> Bitboard
knightAttacks = unsafeAt knightTable
{-# INLINE knightAttacks #-}

-- | Squares a king on the given square attacks.
kingAttacks :: Square -> Bitboard
kingAttacks = unsafeAt kingTable
{-# INLINE kingAttacks #-}

-- | Squares a pawn of the given colour on the given square attacks.
pawnAttacks :: Color -> Square -> Bitboard
pawnAttacks White = unsafeAt whitePawnTable
pawnAttacks Black = unsafeAt blackPawnTable
{-# INLINE pawnAttacks #-}

------------------------------------------------------------------------
-- Rays and sliders

-- Direction indices: 0 N, 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W, 7 NW.
directions :: [(Int, Int)]
directions = [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)]

-- The squares strictly beyond @sq@ in direction (df, dr), in order.
rayList :: (Int, Int) -> Square -> [Square]
rayList (df, dr) sq = go (fileOf sq + df) (rankOf sq + dr)
  where
    go f r
      | f < 0 || f > 7 || r < 0 || r > 7 = []
      | otherwise = mkSquare f r : go (f + df) (r + dr)

toBB :: [Square] -> Bitboard
toBB = foldl' (.|.) 0 . map squareBB

rayTable :: UArray Int Word64
rayTable = listArray (0, 8 * 64 - 1)
  [toBB (rayList d sq) | d <- directions, sq <- [0 .. 63]]
{-# NOINLINE rayTable #-}

ray :: Int -> Square -> Bitboard
ray d sq = unsafeAt rayTable (d * 64 + sq)
{-# INLINE ray #-}

-- Direction indices whose squares increase / decrease along the ray.
posAttack, negAttack :: Int -> Square -> Bitboard -> Bitboard
posAttack d sq occ =
  let r = ray d sq
      blockers = r .&. occ
   in if blockers == 0 then r else r `xor` ray d (countTrailingZeros blockers)
negAttack d sq occ =
  let r = ray d sq
      blockers = r .&. occ
   in if blockers == 0 then r else r `xor` ray d (63 - countLeadingZeros blockers)
{-# INLINE posAttack #-}
{-# INLINE negAttack #-}

-- | Squares a bishop attacks given the occupancy (blockers are included).
bishopAttacks :: Square -> Bitboard -> Bitboard
bishopAttacks sq occ =
  posAttack 1 sq occ .|. posAttack 7 sq occ
    .|. negAttack 3 sq occ .|. negAttack 5 sq occ

-- | Squares a rook attacks given the occupancy (blockers are included).
rookAttacks :: Square -> Bitboard -> Bitboard
rookAttacks sq occ =
  posAttack 0 sq occ .|. posAttack 2 sq occ
    .|. negAttack 4 sq occ .|. negAttack 6 sq occ

-- | Squares a queen attacks given the occupancy (blockers are included).
queenAttacks :: Square -> Bitboard -> Bitboard
queenAttacks sq occ = bishopAttacks sq occ .|. rookAttacks sq occ
{-# INLINE queenAttacks #-}

------------------------------------------------------------------------
-- Between / line tables

betweenTable, lineTable :: UArray Int Word64
betweenTable = listArray (0, 64 * 64 - 1)
  [ betweenSlow a b | a <- [0 .. 63], b <- [0 .. 63] ]
lineTable = listArray (0, 64 * 64 - 1)
  [ lineSlow a b | a <- [0 .. 63], b <- [0 .. 63] ]
{-# NOINLINE betweenTable #-}
{-# NOINLINE lineTable #-}

betweenSlow :: Square -> Square -> Bitboard
betweenSlow a b =
  case [takeWhile (/= b) (rayList d a) | d <- directions, b `elem` rayList d a] of
    (xs : _) -> toBB xs
    [] -> 0

lineSlow :: Square -> Square -> Bitboard
lineSlow a b =
  case [ squareBB a .|. toBB (rayList d a) .|. toBB (rayList (opp d) a)
       | d <- directions, b `elem` rayList d a ] of
    (x : _) -> x
    [] -> 0
  where
    opp (df, dr) = (negate df, negate dr)

-- | The squares strictly between two squares on a common rank, file or
-- diagonal; empty when the squares are not aligned.
between :: Square -> Square -> Bitboard
between a b = unsafeAt betweenTable (a * 64 + b)
{-# INLINE between #-}

-- | The whole rank, file or diagonal through two distinct aligned squares
-- (including both); empty when the squares are not aligned.
line :: Square -> Square -> Bitboard
line a b = unsafeAt lineTable (a * 64 + b)
{-# INLINE line #-}

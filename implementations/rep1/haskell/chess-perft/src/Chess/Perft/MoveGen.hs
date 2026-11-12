-- |
-- Module      : Chess.Perft.MoveGen
-- Description : Legal move generation driven by check and pin information.
--
-- Legality is established up front rather than by trial:
--
-- * the checkers of the king are found; with two checkers only king moves
--   exist, with one every other move must capture the checker or block the
--   line between it and the king (the /check mask/);
-- * pieces pinned to the king are found and confined to the line through
--   the king and the pinner;
-- * king moves are tested against the squares the enemy attacks (with the
--   king lifted off the board so it cannot hide behind itself);
-- * castling checks the vacated and crossed squares for emptiness and attack;
-- * only en passant captures — whose discovered check along a rank cannot be
--   seen from pins — are verified by playing the move.
module Chess.Perft.MoveGen
  ( legalMoves
  , countLegalMoves
  ) where

import Data.Bits (clearBit, complement, popCount, (.&.), (.|.))

import Chess.Perft.Bitboard
import Chess.Perft.Position
import Chess.Perft.Types

-- | All moves a piece on one square can make: origin, legal destinations and
-- whether every such move is a promotion (pawn on its seventh rank).
data Group = Group !Square !Bitboard !Bool

-- | Everything the generator produces for one position.
data Generated = Generated
  { genGroups :: [Group]
  , genSpecial :: [Move]  -- ^ castling and en passant moves
  }

generate :: Position -> Generated
generate pos = Generated groups special
  where
    us = posSideToMove pos
    them = opposite us
    own = occupancy pos us
    enemy = occupancy pos them
    occ = own .|. enemy
    ksq = kingSquare pos us

    checkers = attackersTo pos them ksq occ
    nCheckers = popCount checkers
    checkMask
      | nCheckers == 0 = allSquares
      | otherwise = let c = lowestSquare checkers in between ksq c .|. squareBB c

    -- King: each destination must be unattacked once the king has left.
    occNoKing = occ `clearBit` ksq
    kingTargets =
      foldBits
        (\acc t -> if isAttackedBy pos them t occNoKing then acc else acc .|. squareBB t)
        0
        (kingAttacks ksq .&. complement own)
    kingGroup = [Group ksq kingTargets False | kingTargets /= 0]

    -- Pins.
    enemyRQ = (posRooks pos .|. posQueens pos) .&. enemy
    enemyBQ = (posBishops pos .|. posQueens pos) .&. enemy
    pinners = (rookAttacks ksq enemy .&. enemyRQ) .|. (bishopAttacks ksq enemy .&. enemyBQ)
    pinned = foldBits
      (\acc p ->
         let blockers = between ksq p .&. own
          in if popCount blockers == 1 then acc .|. blockers else acc)
      0
      pinners
    mask sq
      | pinned .&. squareBB sq /= 0 = checkMask .&. line ksq sq
      | otherwise = checkMask

    pieceGroups attacks pieces =
      foldBits
        (\acc sq ->
           let t = attacks sq .&. complement own .&. mask sq
            in if t == 0 then acc else Group sq t False : acc)
        []
        pieces
    mine pt = pieceBB pos pt .&. own
    pieceMoves =
      pieceGroups knightAttacks (mine Knight)
        ++ pieceGroups (\sq -> bishopAttacks sq occ) (mine Bishop)
        ++ pieceGroups (\sq -> rookAttacks sq occ) (mine Rook)
        ++ pieceGroups (\sq -> queenAttacks sq occ) (mine Queen)

    -- Pawns.
    (forward, startRank, promoRank) = if us == White then (8, 1, 6) else (-8, 6, 1)
    empty sq = occ .&. squareBB sq == 0
    pawnGroups =
      foldBits
        (\acc sq ->
           let one = sq + forward
               two = one + forward
               pushes
                 | not (empty one) = 0
                 | rankOf sq == startRank && empty two = squareBB one .|. squareBB two
                 | otherwise = squareBB one
               t = (pushes .|. (pawnAttacks us sq .&. enemy)) .&. mask sq
            in if t == 0 then acc else Group sq t (rankOf sq == promoRank) : acc)
        []
        (mine Pawn)

    groups
      | nCheckers >= 2 = kingGroup
      | otherwise = kingGroup ++ pieceMoves ++ pawnGroups

    -- Special moves.
    enPassant = case enPassantSquare pos of
      Nothing -> []
      Just ep ->
        [ m
        | from <- bitsToList (pawnAttacks them ep .&. mine Pawn)
        , let m = mkMove from ep
        , not (isKingAttacked (makeMove pos m) us) ]

    (homeRank, kingFrom) = if us == White then (0, 4) else (7, 60)
    sq' f = mkSquare f homeRank
    safe s = not (isAttackedBy pos them s occNoKing)
    castles
      | nCheckers /= 0 = []
      | otherwise =
          [ mkMove kingFrom (sq' 6)
          | hasCastlingRight (posCastling pos) us KingSide
          , empty (sq' 5), empty (sq' 6)
          , safe (sq' 5), safe (sq' 6) ]
          ++
          [ mkMove kingFrom (sq' 2)
          | hasCastlingRight (posCastling pos) us QueenSide
          , empty (sq' 1), empty (sq' 2), empty (sq' 3)
          , safe (sq' 3), safe (sq' 2) ]

    special = castles ++ enPassant

-- | The number of legal moves, computed without constructing the moves.
countLegalMoves :: Position -> Int
countLegalMoves pos =
  foldl' add (length (genSpecial g)) (genGroups g)
  where
    g = generate pos
    add !n (Group _ t promo) =
      n + (if promo then 4 * popCount t else popCount t)

-- | All legal moves of the side to move, in no particular order.
legalMoves :: Position -> [Move]
legalMoves pos = foldr expand (genSpecial g) (genGroups g)
  where
    g = generate pos
    expand (Group from t promo) rest = foldBits (flip (add from promo)) rest t
    -- foldBits goes in ascending order; building by consing reverses it, which
    -- is fine as the order is unspecified.
    add from promo sq acc
      | promo =
          mkPromotion from sq Queen : mkPromotion from sq Rook
            : mkPromotion from sq Bishop : mkPromotion from sq Knight : acc
      | otherwise = mkMove from sq : acc

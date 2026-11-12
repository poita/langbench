-- |
-- Module      : Chess.Perft.Position
-- Description : Chess positions: FEN parsing/printing, make-move, attack tests.
module Chess.Perft.Position
  ( Position (..)
  , startPosition
  , startFen
  , parseFen
  , toFen
    -- * Inspecting
  , occupancy
  , pieceBB
  , pieceAt
  , enPassantSquare
  , kingSquare
  , isAttackedBy
  , attackersTo
  , inCheck
  , isKingAttacked
    -- * Playing moves
  , makeMove
  ) where

import Data.Bits (complement, popCount, xor, (.&.), (.|.))
import Data.Char (chr, isDigit, ord, toLower, toUpper)

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray, listArray)

import Chess.Perft.Bitboard
import Chess.Perft.Types

-- | A chess position. Halfmove and fullmove counters are deliberately not
-- tracked: perft has no fifty-move or repetition rule.
data Position = Position
  { posPawns :: !Bitboard
  , posKnights :: !Bitboard
  , posBishops :: !Bitboard
  , posRooks :: !Bitboard
  , posQueens :: !Bitboard
  , posKings :: !Bitboard
  , posWhite :: !Bitboard          -- ^ all white pieces
  , posBlack :: !Bitboard          -- ^ all black pieces
  , posSideToMove :: !Color
  , posCastling :: !CastlingRights
  , posEpRaw :: !Int               -- ^ en passant target square, or 64 for none
  } deriving (Eq, Show)

-- | FEN of the standard initial position.
startFen :: String
startFen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

-- | The standard initial position.
startPosition :: Position
startPosition = either error id (parseFen startFen)

-- | All pieces of one colour.
occupancy :: Position -> Color -> Bitboard
occupancy pos White = posWhite pos
occupancy pos Black = posBlack pos
{-# INLINE occupancy #-}

-- | All pieces (of either colour) of one type.
pieceBB :: Position -> PieceType -> Bitboard
pieceBB pos pt = case pt of
  Pawn -> posPawns pos
  Knight -> posKnights pos
  Bishop -> posBishops pos
  Rook -> posRooks pos
  Queen -> posQueens pos
  King -> posKings pos
{-# INLINE pieceBB #-}

setPieceBB :: PieceType -> Bitboard -> Position -> Position
setPieceBB pt bb pos = case pt of
  Pawn -> pos {posPawns = bb}
  Knight -> pos {posKnights = bb}
  Bishop -> pos {posBishops = bb}
  Rook -> pos {posRooks = bb}
  Queen -> pos {posQueens = bb}
  King -> pos {posKings = bb}
{-# INLINE setPieceBB #-}

-- | The piece type standing on a square, ignoring colour.
pieceTypeAt :: Position -> Square -> Maybe PieceType
pieceTypeAt pos sq
  | posPawns pos .&. b /= 0 = Just Pawn
  | posKnights pos .&. b /= 0 = Just Knight
  | posBishops pos .&. b /= 0 = Just Bishop
  | posRooks pos .&. b /= 0 = Just Rook
  | posQueens pos .&. b /= 0 = Just Queen
  | posKings pos .&. b /= 0 = Just King
  | otherwise = Nothing
  where
    b = squareBB sq

-- | The piece standing on a square, if any.
pieceAt :: Position -> Square -> Maybe (Color, PieceType)
pieceAt pos sq = do
  pt <- pieceTypeAt pos sq
  let c = if posWhite pos .&. squareBB sq /= 0 then White else Black
  pure (c, pt)

-- | The en passant target square, if one is set.
enPassantSquare :: Position -> Maybe Square
enPassantSquare pos
  | posEpRaw pos >= 64 = Nothing
  | otherwise = Just (posEpRaw pos)

-- | Square of the given side's king. The position must contain that king.
kingSquare :: Position -> Color -> Square
kingSquare pos c = lowestSquare (posKings pos .&. occupancy pos c)
{-# INLINE kingSquare #-}

-- | The pieces of colour @by@ that attack @sq@, given an occupancy for the
-- sliders' lines of sight (which lets callers "lift" a piece off the board).
attackersTo :: Position -> Color -> Square -> Bitboard -> Bitboard
attackersTo pos by sq occ =
  (pawnAttacks (opposite by) sq .&. posPawns pos .&. theirs)
    .|. (knightAttacks sq .&. posKnights pos .&. theirs)
    .|. (kingAttacks sq .&. posKings pos .&. theirs)
    .|. (bishopAttacks sq occ .&. (posBishops pos .|. posQueens pos) .&. theirs)
    .|. (rookAttacks sq occ .&. (posRooks pos .|. posQueens pos) .&. theirs)
  where
    theirs = occupancy pos by

-- | Is @sq@ attacked by any piece of colour @by@, with sliders seeing through
-- squares absent from @occ@?
isAttackedBy :: Position -> Color -> Square -> Bitboard -> Bool
isAttackedBy pos by sq occ = attackersTo pos by sq occ /= 0
{-# INLINE isAttackedBy #-}

-- | Is the given side's king attacked?
isKingAttacked :: Position -> Color -> Bool
isKingAttacked pos c =
  isAttackedBy pos (opposite c) (kingSquare pos c) (posWhite pos .|. posBlack pos)

-- | Is the side to move in check?
inCheck :: Position -> Bool
inCheck pos = isKingAttacked pos (posSideToMove pos)

------------------------------------------------------------------------
-- Making moves

-- Castling rights surviving a move touching each square.
castlingMask :: UArray Int Int
castlingMask = listArray (0, 63) [m sq | sq <- [0 .. 63 :: Int]]
  where
    m 0 = 15 - 2    -- a1
    m 7 = 15 - 1    -- h1
    m 4 = 15 - 3    -- e1
    m 56 = 15 - 8   -- a8
    m 63 = 15 - 4   -- h8
    m 60 = 15 - 12  -- e8
    m _ = 15
{-# NOINLINE castlingMask #-}

-- | Play a move that is legal in the position (as produced by
-- "Chess.Perft.MoveGen"). The result is unspecified for other moves.
--
-- The en passant square is set after every two-square pawn advance, whether
-- or not an enemy pawn can use it.
makeMove :: Position -> Move -> Position
makeMove pos m =
  Position
    { posPawns = pawns'
    , posKnights = knights'
    , posBishops = bishops'
    , posRooks = rooks'
    , posQueens = queens'
    , posKings = kings'
    , posWhite = white'
    , posBlack = black'
    , posSideToMove = them
    , posCastling = CastlingRights (rights .&. unsafeAt castlingMask from .&. unsafeAt castlingMask to)
    , posEpRaw = if isPawn && abs (to - from) == 16 then (from + to) `div` 2 else 64
    }
  where
    us = posSideToMove pos
    them = opposite us
    from = moveFrom m
    to = moveTo m
    fromBB = squareBB from
    toBB' = squareBB to
    CastlingRights rights = posCastling pos

    isPawn = posPawns pos .&. fromBB /= 0
    isKing = posKings pos .&. fromBB /= 0
    isEp = isPawn && to == posEpRaw pos
    capSq
      | isEp = if us == White then to - 8 else to + 8
      | otherwise = to
    capBB = squareBB capSq
    -- Everything the enemy loses.
    enemyOld = occupancy pos them
    enemyNew = enemyOld .&. complement capBB
    -- Bitboards after removing any captured piece.
    cap = capBB
    pawns0 = posPawns pos .&. complement cap
    knights0 = posKnights pos .&. complement cap
    bishops0 = posBishops pos .&. complement cap
    rooks0 = posRooks pos .&. complement cap
    queens0 = posQueens pos .&. complement cap
    kings0 = posKings pos

    promo = movePromotion m
    moveBits = fromBB .|. toBB'
    -- The mover leaves 'from'; it arrives on 'to' as itself or as its
    -- promotion piece.
    pawns1 = if isPawn then pawns0 .&. complement fromBB else pawns0
    pawns' = case promo of
      Nothing | isPawn -> pawns1 .|. toBB'
      _ -> pawns1
    knights' = adjust Knight knights0
    bishops' = adjust Bishop bishops0
    queens' = adjust Queen queens0
    rooks1 = adjust Rook rooks0
    kings' = if isKing then kings0 `xor` moveBits else kings0

    adjust pt bb =
      let leaving = if not isPawn && not isKing && pieceMover pt then moveBits else 0
          arriving = if promo == Just pt then toBB' else 0
       in (bb `xor` leaving) .|. arriving
    pieceMover pt = pieceBB pos pt .&. fromBB /= 0

    -- Castling also relocates a rook.
    castleRook
      | isKing && abs (to - from) == 2 =
          if to > from then squareBB (from + 3) .|. squareBB (from + 1)
                       else squareBB (from - 4) .|. squareBB (from - 1)
      | otherwise = 0
    rooks' = rooks1 `xor` castleRook

    ownOld = occupancy pos us
    ownNew = (ownOld `xor` moveBits) `xor` castleRook
    (white', black')
      | us == White = (ownNew, enemyNew)
      | otherwise = (enemyNew, ownNew)

------------------------------------------------------------------------
-- FEN

-- | Parse a FEN record. The halfmove and fullmove fields must be present (as
-- non-negative integers) but are ignored.
--
-- Inconsistent castling rights (king or rook not on its home square) and an
-- en passant square with no capturable pawn behind it are silently dropped.
-- Positions without exactly one king per side, with pawns on the first or
-- last rank, or with the side not to move in check are rejected.
parseFen :: String -> Either String Position
parseFen s = case words s of
  [placement, side, castling, ep, half, full]
    | all isDigit half && not (null half) && all isDigit full && not (null full) -> do
        rows <- parsePlacement placement
        stm <- case side of
          "w" -> Right White
          "b" -> Right Black
          _ -> Left ("bad side to move: " ++ side)
        rights <- maybe (Left ("bad castling field: " ++ castling)) Right (castlingFromString castling)
        epSq <- case ep of
          "-" -> Right Nothing
          _ -> maybe (Left ("bad en passant square: " ++ ep)) (Right . Just) (parseSquare ep)
        build rows stm rights epSq
  _ -> Left ("malformed FEN: " ++ s)

build :: [(Square, Color, PieceType)] -> Color -> CastlingRights -> Maybe Square -> Either String Position
build pcs stm rights epSq = do
  let pos0 = foldl' place empty pcs
      empty = Position 0 0 0 0 0 0 0 0 stm noCastling 64
      kingsOf c = popCount (posKings pos0 .&. occupancy pos0 c)
  if kingsOf White /= 1 || kingsOf Black /= 1
    then Left "each side must have exactly one king"
    else Right ()
  if posPawns pos0 .&. (rank1 .|. rank8) /= 0
    then Left "pawns on the first or last rank"
    else Right ()
  let pos1 = pos0 {posCastling = sanitizeRights pos0 rights, posEpRaw = sanitizeEp pos0 stm epSq}
  if isKingAttacked pos1 (opposite stm)
    then Left "the side not to move is in check"
    else Right pos1
  where
    rank1 = 0xFF
    rank8 = 0xFF00000000000000

place :: Position -> (Square, Color, PieceType) -> Position
place pos (sq, c, pt) =
  let b = squareBB sq
      pos' = setPieceBB pt (pieceBB pos pt .|. b) pos
   in case c of
        White -> pos' {posWhite = posWhite pos' .|. b}
        Black -> pos' {posBlack = posBlack pos' .|. b}

sanitizeRights :: Position -> CastlingRights -> CastlingRights
sanitizeRights pos (CastlingRights r) = CastlingRights (r .&. ok)
  where
    has c pt sq = pieceAt pos sq == Just (c, pt)
    ok = sum
      [ bitFor White KingSide 4 7, bitFor White QueenSide 4 0
      , bitFor Black KingSide 60 63, bitFor Black QueenSide 60 56 ]
    bitFor c s k rk
      | has c King k && has c Rook rk = castlingBit c s
      | otherwise = 0

sanitizeEp :: Position -> Color -> Maybe Square -> Int
sanitizeEp _ _ Nothing = 64
sanitizeEp pos stm (Just sq)
  | rankOf sq == wantRank
  , pieceAt pos sq == Nothing
  , pieceAt pos pawnSq == Just (opposite stm, Pawn) = sq
  | otherwise = 64
  where
    (wantRank, pawnSq) = if stm == White then (5, sq - 8) else (2, sq + 8)

parsePlacement :: String -> Either String [(Square, Color, PieceType)]
parsePlacement str = do
  let rows = splitOn '/' str
  if length rows /= 8 then Left ("expected 8 ranks: " ++ str) else Right ()
  concat <$> sequence (zipWith parseRank [7, 6 .. 0] rows)
  where
    parseRank r row = go 0 row
      where
        go f [] | f == 8 = Right []
                | otherwise = Left ("rank does not have 8 files: " ++ row)
        go f (ch : rest)
          | isDigit ch && ch >= '1' && ch <= '8' = go (f + ord ch - ord '0') rest
          | f >= 8 = Left ("rank too long: " ++ row)
          | otherwise = case lookup (toLower ch) pieces of
              Just pt ->
                let c = if ch == toUpper ch then White else Black
                 in ((mkSquare f r, c, pt) :) <$> go (f + 1) rest
              Nothing -> Left ("bad piece character: " ++ [ch])
    pieces = [('p', Pawn), ('n', Knight), ('b', Bishop), ('r', Rook), ('q', Queen), ('k', King)]

splitOn :: Char -> String -> [String]
splitOn d s = case break (== d) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn d rest

-- | Render a position as FEN (with halfmove clock @0@ and fullmove @1@).
toFen :: Position -> String
toFen pos =
  unwords
    [ joinRanks
    , if posSideToMove pos == White then "w" else "b"
    , castlingToString (posCastling pos)
    , maybe "-" squareName (enPassantSquare pos)
    , "0"
    , "1"
    ]
  where
    joinRanks = foldr1 (\a b -> a ++ "/" ++ b) (map rank [7, 6 .. 0])
    rank r = go (0 :: Int) [0 .. 7]
      where
        go n [] = digits n
        go n (f : fs) = case pieceAt pos (mkSquare f r) of
          Nothing -> go (n + 1) fs
          Just (c, pt) -> digits n ++ [pieceChar c pt] ++ go 0 fs
    digits 0 = ""
    digits n = [chr (ord '0' + n)]
    pieceChar c pt =
      let ch = case pt of
            Pawn -> 'p'; Knight -> 'n'; Bishop -> 'b'
            Rook -> 'r'; Queen -> 'q'; King -> 'k'
       in if c == White then toUpper ch else ch

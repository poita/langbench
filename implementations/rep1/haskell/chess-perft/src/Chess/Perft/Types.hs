-- |
-- Module      : Chess.Perft.Types
-- Description : Basic chess vocabulary: colours, pieces, squares, moves.
--
-- Squares are numbered @0..63@ with @a1 = 0@, @b1 = 1@, …, @h1 = 7@,
-- @a2 = 8@, …, @h8 = 63@ (little-endian rank-file mapping).
module Chess.Perft.Types
  ( -- * Colours and pieces
    Color (..)
  , opposite
  , PieceType (..)
    -- * Squares
  , Square
  , mkSquare
  , fileOf
  , rankOf
  , squareName
  , parseSquare
    -- * Castling rights
  , CastlingRights (..)
  , noCastling
  , allCastling
  , CastleSide (..)
  , hasCastlingRight
  , castlingBit
  , castlingToString
  , castlingFromString
    -- * Moves
  , Move
  , mkMove
  , mkPromotion
  , moveFrom
  , moveTo
  , movePromotion
  , moveToUci
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (chr, isDigit, ord)

-- | The two sides.
data Color = White | Black
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | The other side.
opposite :: Color -> Color
opposite White = Black
opposite Black = White
{-# INLINE opposite #-}

-- | The six kinds of chess piece.
data PieceType = Pawn | Knight | Bishop | Rook | Queen | King
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | A board square, @0@ (a1) to @63@ (h8).
type Square = Int

-- | Build a square from a zero-based file (@a = 0@) and rank (@1 = 0@).
mkSquare :: Int -> Int -> Square
mkSquare file rank = rank * 8 + file
{-# INLINE mkSquare #-}

-- | Zero-based file of a square (@a = 0@ … @h = 7@).
fileOf :: Square -> Int
fileOf sq = sq .&. 7
{-# INLINE fileOf #-}

-- | Zero-based rank of a square (rank 1 @= 0@ … rank 8 @= 7@).
rankOf :: Square -> Int
rankOf sq = sq `shiftR` 3
{-# INLINE rankOf #-}

-- | Algebraic name of a square, e.g. @squareName 12 == "e2"@.
squareName :: Square -> String
squareName sq = [chr (ord 'a' + fileOf sq), chr (ord '1' + rankOf sq)]

-- | Parse an algebraic square name such as @"e3"@.
parseSquare :: String -> Maybe Square
parseSquare [f, r]
  | f >= 'a' && f <= 'h' && isDigit r && r >= '1' && r <= '8' =
      Just (mkSquare (ord f - ord 'a') (ord r - ord '1'))
parseSquare _ = Nothing

-- | The set of castling rights still available, stored as four bits.
newtype CastlingRights = CastlingRights Int
  deriving (Eq, Show)

-- | Which wing a castling move goes to.
data CastleSide = KingSide | QueenSide
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | No castling rights at all.
noCastling :: CastlingRights
noCastling = CastlingRights 0

-- | All four castling rights.
allCastling :: CastlingRights
allCastling = CastlingRights 15

-- | The bit representing one castling right.
castlingBit :: Color -> CastleSide -> Int
castlingBit White KingSide = 1
castlingBit White QueenSide = 2
castlingBit Black KingSide = 4
castlingBit Black QueenSide = 8
{-# INLINE castlingBit #-}

-- | Does the given side still hold the given castling right?
hasCastlingRight :: CastlingRights -> Color -> CastleSide -> Bool
hasCastlingRight (CastlingRights r) c s = r .&. castlingBit c s /= 0
{-# INLINE hasCastlingRight #-}

-- | FEN castling field (@"KQkq"@ subset or @"-"@).
castlingToString :: CastlingRights -> String
castlingToString r =
  case [ch | (ch, c, s) <- table, hasCastlingRight r c s] of
    [] -> "-"
    xs -> xs
  where
    table =
      [ ('K', White, KingSide), ('Q', White, QueenSide)
      , ('k', Black, KingSide), ('q', Black, QueenSide) ]

-- | Parse a FEN castling field.
castlingFromString :: String -> Maybe CastlingRights
castlingFromString "-" = Just noCastling
castlingFromString [] = Nothing
castlingFromString s = CastlingRights . foldr (.|.) 0 <$> mapM bitOf s
  where
    bitOf 'K' = Just (castlingBit White KingSide)
    bitOf 'Q' = Just (castlingBit White QueenSide)
    bitOf 'k' = Just (castlingBit Black KingSide)
    bitOf 'q' = Just (castlingBit Black QueenSide)
    bitOf _ = Nothing

-- | A move, packed into an 'Int': origin (6 bits), destination (6 bits) and
-- a promotion piece (3 bits, @0@ for none).
--
-- A move carries no other flags: castling is recognised as a king moving two
-- files, and en passant as a pawn moving to the position's en passant square.
-- Moves are therefore only meaningful relative to the position they were
-- generated from.
newtype Move = Move Int
  deriving (Eq, Ord)

instance Show Move where
  show = moveToUci

-- | A non-promoting move.
mkMove :: Square -> Square -> Move
mkMove from to = Move (from .|. (to `shiftL` 6))
{-# INLINE mkMove #-}

-- | A promoting move; the piece must be 'Knight', 'Bishop', 'Rook' or 'Queen'.
mkPromotion :: Square -> Square -> PieceType -> Move
mkPromotion from to pt =
  Move (from .|. (to `shiftL` 6) .|. ((fromEnum pt) `shiftL` 12))
{-# INLINE mkPromotion #-}

-- | Origin square.
moveFrom :: Move -> Square
moveFrom (Move m) = m .&. 63
{-# INLINE moveFrom #-}

-- | Destination square (the king's destination for castling).
moveTo :: Move -> Square
moveTo (Move m) = (m `shiftR` 6) .&. 63
{-# INLINE moveTo #-}

-- | Promotion piece, if any.
movePromotion :: Move -> Maybe PieceType
movePromotion (Move m) = case m `shiftR` 12 of
  0 -> Nothing
  n -> Just (toEnum n)
{-# INLINE movePromotion #-}

-- | UCI long algebraic notation, e.g. @"e2e4"@, @"e1g1"@, @"a7a8q"@.
moveToUci :: Move -> String
moveToUci m =
  squareName (moveFrom m) ++ squareName (moveTo m) ++ promo
  where
    promo = case movePromotion m of
      Just Queen -> "q"
      Just Rook -> "r"
      Just Bishop -> "b"
      Just Knight -> "n"
      _ -> ""

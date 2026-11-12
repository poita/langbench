#include "chessperft/position.hpp"

#include "chessperft/attacks.hpp"

namespace chessperft {

namespace {

// Castling rights that survive a move touching each square (as origin or
// destination): moving the king or moving/capturing a rook on its corner
// clears the matching rights.
struct CastleMasks {
  std::uint8_t mask[64];
  constexpr CastleMasks() : mask() {
    for (auto& m : mask) m = kAllCastling;
    mask[0] = kAllCastling & ~kWhiteQueenside;
    mask[7] = kAllCastling & ~kWhiteKingside;
    mask[4] = kAllCastling & ~(kWhiteKingside | kWhiteQueenside);
    mask[56] = kAllCastling & ~kBlackQueenside;
    mask[63] = kAllCastling & ~kBlackKingside;
    mask[60] = kAllCastling & ~(kBlackKingside | kBlackQueenside);
  }
};
constexpr CastleMasks kCastleMasks;

}  // namespace

Position::Position() noexcept { board_.fill(Piece::None); }

void Position::addPiece(Square s, Piece p) noexcept {
  board_[s] = p;
  byType_[static_cast<int>(typeOf(p))] |= bit(s);
  byColor_[static_cast<int>(colorOf(p))] |= bit(s);
}

void Position::removePiece(Square s) noexcept {
  const Piece p = board_[s];
  board_[s] = Piece::None;
  byType_[static_cast<int>(typeOf(p))] &= ~bit(s);
  byColor_[static_cast<int>(colorOf(p))] &= ~bit(s);
}

void Position::setPiece(Square s, Piece p) noexcept {
  if (board_[s] != Piece::None) removePiece(s);
  if (p != Piece::None) addPiece(s, p);
}

Bitboard Position::attackersTo(Square s, Color by, Bitboard occ) const noexcept {
  const Bitboard diagonal = pieces(PieceType::Bishop) | pieces(PieceType::Queen);
  const Bitboard straight = pieces(PieceType::Rook) | pieces(PieceType::Queen);
  return (((pawnAttacks(~by, s) & pieces(PieceType::Pawn)) |
           (knightAttacks(s) & pieces(PieceType::Knight)) |
           (kingAttacks(s) & pieces(PieceType::King)) |
           (bishopAttacks(s, occ) & diagonal) | (rookAttacks(s, occ) & straight)) &
          pieces(by));
}

bool Position::isAttacked(Square s, Color by, Bitboard occ) const noexcept {
  return attackersTo(s, by, occ) != 0;
}

void Position::makeMove(Move m) noexcept {
  const Square from = m.from(), to = m.to();
  const Color us = side_;
  const Piece moving = board_[from];

  ep_ = kNoSquare;
  if (m.kind() == MoveKind::EnPassant) {
    removePiece(us == Color::White ? to - 8 : to + 8);
  } else if (board_[to] != Piece::None) {
    removePiece(to);
  }
  removePiece(from);
  addPiece(to, m.isPromotion() ? makePiece(us, m.promotionType()) : moving);

  switch (m.kind()) {
    case MoveKind::Castle: {
      const bool kingside = to > from;
      const Square rookFrom = kingside ? from + 3 : from - 4;
      const Square rookTo = kingside ? from + 1 : from - 1;
      const Piece rook = board_[rookFrom];
      removePiece(rookFrom);
      addPiece(rookTo, rook);
      break;
    }
    case MoveKind::DoublePush:
      ep_ = (from + to) / 2;
      break;
    default:
      break;
  }

  castling_ &= kCastleMasks.mask[from] & kCastleMasks.mask[to];
  side_ = ~us;
}

}  // namespace chessperft

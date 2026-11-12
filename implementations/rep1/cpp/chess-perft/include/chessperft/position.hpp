// Board state and move execution.
#pragma once

#include <array>
#include <cstdint>

#include "chessperft/move.hpp"
#include "chessperft/types.hpp"

namespace chessperft {

/// Castling-right flags, combined with bitwise or.
enum CastlingRight : std::uint8_t {
  kWhiteKingside = 1,
  kWhiteQueenside = 2,
  kBlackKingside = 4,
  kBlackQueenside = 8,
  kAllCastling = 15
};

/// A chess position: piece placement, side to move, castling rights and the
/// en passant target square. Move counters are not tracked (perft has no
/// fifty-move or repetition rules).
///
/// `Position` is a small value type; the search uses copy-make (copy, then
/// `makeMove` on the copy), so there is no unmake.
class Position {
 public:
  /// An empty board, white to move, no castling, no en passant.
  Position() noexcept;

  /// The standard starting position.
  static Position startPosition();

  // --- setup (used by the FEN parser; keeps all indexes consistent) ---------
  /// Puts `p` on `s`, replacing whatever was there; `Piece::None` clears it.
  void setPiece(Square s, Piece p) noexcept;
  void setSideToMove(Color c) noexcept { side_ = c; }
  void setCastlingRights(std::uint8_t rights) noexcept { castling_ = rights; }
  void setEnPassantSquare(Square s) noexcept { ep_ = s; }

  // --- queries --------------------------------------------------------------
  Piece pieceAt(Square s) const noexcept { return board_[s]; }
  Color sideToMove() const noexcept { return side_; }
  std::uint8_t castlingRights() const noexcept { return castling_; }
  /// En passant target square, or `kNoSquare`.
  Square enPassantSquare() const noexcept { return ep_; }

  Bitboard occupied() const noexcept { return byColor_[0] | byColor_[1]; }
  Bitboard pieces(Color c) const noexcept { return byColor_[static_cast<int>(c)]; }
  Bitboard pieces(PieceType t) const noexcept { return byType_[static_cast<int>(t)]; }
  Bitboard pieces(Color c, PieceType t) const noexcept { return pieces(c) & pieces(t); }
  /// Square of `c`'s king. The position must contain one.
  Square kingSquare(Color c) const noexcept { return lsb(pieces(c, PieceType::King)); }

  /// Pieces of colour `by` that attack `s`, with sliders blocked by `occ`.
  Bitboard attackersTo(Square s, Color by, Bitboard occ) const noexcept;
  /// Is `s` attacked by any piece of colour `by` (blockers = `occ`)?
  bool isAttacked(Square s, Color by, Bitboard occ) const noexcept;
  bool isAttacked(Square s, Color by) const noexcept { return isAttacked(s, by, occupied()); }
  /// Is the side to move in check?
  bool inCheck() const noexcept { return isAttacked(kingSquare(side_), ~side_); }

  // --- execution ------------------------------------------------------------
  /// Plays a move that is pseudo-legal in this position (castling and
  /// en passant are recognised from `Move::kind()`).
  void makeMove(Move m) noexcept;

  friend bool operator==(const Position& a, const Position& b) noexcept {
    return a.board_ == b.board_ && a.side_ == b.side_ &&
           a.castling_ == b.castling_ && a.ep_ == b.ep_;
  }

 private:
  void addPiece(Square s, Piece p) noexcept;
  void removePiece(Square s) noexcept;

  std::array<Bitboard, kPieceTypeCount> byType_{};
  std::array<Bitboard, 2> byColor_{};
  std::array<Piece, 64> board_;
  Color side_ = Color::White;
  std::uint8_t castling_ = 0;
  Square ep_ = kNoSquare;
};

}  // namespace chessperft

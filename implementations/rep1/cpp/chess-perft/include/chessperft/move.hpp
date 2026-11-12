// Move representation and a fixed-capacity move list.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

#include "chessperft/types.hpp"

namespace chessperft {

/// What special handling a move needs. Captures are not a kind of their own:
/// they are recognised from the board.
enum class MoveKind : std::uint8_t {
  Quiet,        ///< ordinary move or capture
  DoublePush,   ///< pawn advancing two squares
  EnPassant,    ///< en passant capture (`to` is the ep target square)
  Castle,       ///< king move of a castling (`from`/`to` are the king's)
  PromoKnight,  ///< promotions: the piece the pawn becomes
  PromoBishop,
  PromoRook,
  PromoQueen
};

/// A move packed into 16 bits: 6 bits origin, 6 bits destination, 3 bits kind.
class Move {
 public:
  constexpr Move() noexcept = default;
  constexpr Move(Square from, Square to, MoveKind kind = MoveKind::Quiet) noexcept
      : data_(static_cast<std::uint16_t>(from | (to << 6) |
                                         (static_cast<int>(kind) << 12))) {}

  constexpr Square from() const noexcept { return data_ & 63; }
  constexpr Square to() const noexcept { return (data_ >> 6) & 63; }
  constexpr MoveKind kind() const noexcept {
    return static_cast<MoveKind>(data_ >> 12);
  }
  constexpr bool isPromotion() const noexcept {
    return kind() >= MoveKind::PromoKnight;
  }
  /// Piece a promoting pawn becomes; only meaningful if `isPromotion()`.
  constexpr PieceType promotionType() const noexcept {
    switch (kind()) {
      case MoveKind::PromoKnight: return PieceType::Knight;
      case MoveKind::PromoBishop: return PieceType::Bishop;
      case MoveKind::PromoRook: return PieceType::Rook;
      default: return PieceType::Queen;
    }
  }

  /// UCI long algebraic notation, e.g. "e2e4", "e1g1", "a7a8q".
  std::string toUci() const;

  friend constexpr bool operator==(Move a, Move b) noexcept {
    return a.data_ == b.data_;
  }

 private:
  std::uint16_t data_ = 0;
};

/// Fixed-capacity list of moves (no allocation). 256 exceeds the maximum
/// number of legal moves (218) in any chess position.
class MoveList {
 public:
  static constexpr std::size_t kCapacity = 256;

  void push_back(Move m) noexcept { moves_[size_++] = m; }
  std::size_t size() const noexcept { return size_; }
  bool empty() const noexcept { return size_ == 0; }
  Move operator[](std::size_t i) const noexcept { return moves_[i]; }
  const Move* begin() const noexcept { return moves_.data(); }
  const Move* end() const noexcept { return moves_.data() + size_; }

 private:
  std::array<Move, kCapacity> moves_;
  std::size_t size_ = 0;
};

}  // namespace chessperft

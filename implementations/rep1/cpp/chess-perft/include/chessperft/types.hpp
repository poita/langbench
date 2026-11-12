// Basic board vocabulary: squares, colours, pieces and bitboards.
#pragma once

#include <bit>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace chessperft {

/// A set of squares, one bit per square (bit 0 = a1, bit 63 = h8).
using Bitboard = std::uint64_t;

/// A square index 0..63 laid out little-endian rank-file: a1 = 0, b1 = 1,
/// ..., h1 = 7, a2 = 8, ..., h8 = 63.
using Square = int;

/// Sentinel meaning "no square" (e.g. no en passant target).
inline constexpr Square kNoSquare = 64;

enum class Color : std::uint8_t { White = 0, Black = 1 };

/// The opposite colour.
constexpr Color operator~(Color c) noexcept {
  return static_cast<Color>(static_cast<std::uint8_t>(c) ^ 1U);
}

enum class PieceType : std::uint8_t { Pawn, Knight, Bishop, Rook, Queen, King };
inline constexpr int kPieceTypeCount = 6;

/// A coloured piece, or `None` for an empty square.
enum class Piece : std::uint8_t {
  WhitePawn, WhiteKnight, WhiteBishop, WhiteRook, WhiteQueen, WhiteKing,
  BlackPawn, BlackKnight, BlackBishop, BlackRook, BlackQueen, BlackKing,
  None
};

constexpr Piece makePiece(Color c, PieceType t) noexcept {
  return static_cast<Piece>(static_cast<int>(c) * kPieceTypeCount +
                            static_cast<int>(t));
}
/// Type of a non-empty piece.
constexpr PieceType typeOf(Piece p) noexcept {
  return static_cast<PieceType>(static_cast<int>(p) % kPieceTypeCount);
}
/// Colour of a non-empty piece.
constexpr Color colorOf(Piece p) noexcept {
  return static_cast<int>(p) >= kPieceTypeCount ? Color::Black : Color::White;
}

// --- squares ---------------------------------------------------------------

constexpr int fileOf(Square s) noexcept { return s & 7; }
constexpr int rankOf(Square s) noexcept { return s >> 3; }
constexpr Square makeSquare(int file, int rank) noexcept {
  return rank * 8 + file;
}

/// "e4" -> square; `std::nullopt` if the text is not a valid square name.
std::optional<Square> parseSquare(std::string_view text) noexcept;
/// Square -> "e4". `kNoSquare` yields "-".
std::string squareName(Square s);

// --- bitboards -------------------------------------------------------------

constexpr Bitboard bit(Square s) noexcept { return Bitboard{1} << s; }
constexpr int popcount(Bitboard b) noexcept { return std::popcount(b); }
/// Index of the lowest set bit; `b` must be non-zero.
constexpr Square lsb(Bitboard b) noexcept { return std::countr_zero(b); }
/// Index of the highest set bit; `b` must be non-zero.
constexpr Square msb(Bitboard b) noexcept { return 63 - std::countl_zero(b); }
/// Removes and returns the lowest set bit's square; `b` must be non-zero.
constexpr Square popLsb(Bitboard& b) noexcept {
  const Square s = lsb(b);
  b &= b - 1;
  return s;
}

inline constexpr Bitboard kRank1 = 0x00000000000000FFULL;
inline constexpr Bitboard kRank8 = kRank1 << 56;

}  // namespace chessperft

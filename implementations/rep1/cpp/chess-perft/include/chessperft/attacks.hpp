// Precomputed attack sets for every piece type, plus the geometric helpers
// (`between`, `line`) used for check evasion and pin handling.
//
// The tables are built by dynamic initialisation of `detail::kTables` when the
// library is loaded; do not call these functions from the static initialiser
// of another translation unit.
#pragma once

#include "chessperft/types.hpp"

namespace chessperft {
namespace detail {

// Ray directions. The first four increase the square index, the last four
// decrease it; `d ^ 4` is the opposite direction.
enum Dir { N, E, NE, NW, S, W, SW, SE };

struct AttackTables {
  Bitboard knight[64];
  Bitboard king[64];
  Bitboard pawn[2][64];
  Bitboard ray[8][64];       // squares strictly beyond `s` in direction d
  Bitboard between[64][64];  // squares strictly between two aligned squares
  Bitboard line[64][64];     // the whole line through two aligned squares
  AttackTables();
};

extern const AttackTables kTables;

template <Dir D>
inline Bitboard positiveRay(Square s, Bitboard occ) noexcept {
  Bitboard attacks = kTables.ray[D][s];
  if (const Bitboard blockers = attacks & occ) attacks ^= kTables.ray[D][lsb(blockers)];
  return attacks;
}

template <Dir D>
inline Bitboard negativeRay(Square s, Bitboard occ) noexcept {
  Bitboard attacks = kTables.ray[D][s];
  if (const Bitboard blockers = attacks & occ) attacks ^= kTables.ray[D][msb(blockers)];
  return attacks;
}

}  // namespace detail

inline Bitboard knightAttacks(Square s) noexcept { return detail::kTables.knight[s]; }
inline Bitboard kingAttacks(Square s) noexcept { return detail::kTables.king[s]; }
/// Squares a pawn of colour `c` on `s` attacks.
inline Bitboard pawnAttacks(Color c, Square s) noexcept {
  return detail::kTables.pawn[static_cast<int>(c)][s];
}

/// Squares a bishop on `s` attacks given the occupied squares `occ`
/// (the first blocker in each direction is included).
inline Bitboard bishopAttacks(Square s, Bitboard occ) noexcept {
  using namespace detail;
  return positiveRay<NE>(s, occ) | positiveRay<NW>(s, occ) |
         negativeRay<SE>(s, occ) | negativeRay<SW>(s, occ);
}
/// Squares a rook on `s` attacks given the occupied squares `occ`.
inline Bitboard rookAttacks(Square s, Bitboard occ) noexcept {
  using namespace detail;
  return positiveRay<N>(s, occ) | positiveRay<E>(s, occ) |
         negativeRay<S>(s, occ) | negativeRay<W>(s, occ);
}
inline Bitboard queenAttacks(Square s, Bitboard occ) noexcept {
  return bishopAttacks(s, occ) | rookAttacks(s, occ);
}

/// Squares strictly between `a` and `b` if they share a rank, file or
/// diagonal; otherwise empty.
inline Bitboard between(Square a, Square b) noexcept { return detail::kTables.between[a][b]; }
/// The entire rank, file or diagonal through `a` and `b` (including both);
/// empty if they are not aligned.
inline Bitboard line(Square a, Square b) noexcept { return detail::kTables.line[a][b]; }

}  // namespace chessperft

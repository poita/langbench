#include "chessperft/attacks.hpp"

namespace chessperft {
namespace detail {

namespace {

constexpr int kDirFile[8] = {0, 1, 1, -1, 0, -1, -1, 1};
constexpr int kDirRank[8] = {1, 0, 1, 1, -1, 0, -1, -1};

bool onBoard(int file, int rank) { return file >= 0 && file < 8 && rank >= 0 && rank < 8; }

}  // namespace

AttackTables::AttackTables() : knight(), king(), pawn(), ray(), between(), line() {
  constexpr int kKnightSteps[8][2] = {{1, 2},  {2, 1},  {2, -1},  {1, -2},
                                      {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2}};
  for (Square s = 0; s < 64; ++s) {
    const int f = fileOf(s), r = rankOf(s);
    for (const auto& step : kKnightSteps) {
      if (onBoard(f + step[0], r + step[1])) {
        knight[s] |= bit(makeSquare(f + step[0], r + step[1]));
      }
    }
    for (int d = 0; d < 8; ++d) {
      // King step and ray in direction d.
      if (onBoard(f + kDirFile[d], r + kDirRank[d])) {
        king[s] |= bit(makeSquare(f + kDirFile[d], r + kDirRank[d]));
      }
      for (int nf = f + kDirFile[d], nr = r + kDirRank[d]; onBoard(nf, nr);
           nf += kDirFile[d], nr += kDirRank[d]) {
        ray[d][s] |= bit(makeSquare(nf, nr));
      }
    }
    for (int df : {-1, 1}) {
      if (onBoard(f + df, r + 1)) pawn[0][s] |= bit(makeSquare(f + df, r + 1));
      if (onBoard(f + df, r - 1)) pawn[1][s] |= bit(makeSquare(f + df, r - 1));
    }
  }
  for (Square a = 0; a < 64; ++a) {
    for (int d = 0; d < 8; ++d) {
      for (Bitboard targets = ray[d][a]; targets;) {
        const Square b = popLsb(targets);
        between[a][b] = ray[d][a] & ~ray[d][b] & ~bit(b);
        line[a][b] = ray[d][a] | ray[d ^ 4][a] | bit(a);
      }
    }
  }
}

const AttackTables kTables;

}  // namespace detail
}  // namespace chessperft

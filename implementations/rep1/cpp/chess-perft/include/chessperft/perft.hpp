// Perft node counting and divide.
#pragma once

#include <cstdint>
#include <vector>

#include "chessperft/move.hpp"
#include "chessperft/position.hpp"

namespace chessperft {

/// Number of leaf nodes reached by every sequence of `depth` legal moves from
/// `pos`. `perft(pos, 0) == 1`. Leaves are counted, not visited: at depth 1
/// the result is the number of generated legal moves.
std::uint64_t perft(const Position& pos, int depth);

/// One root move and the number of nodes beneath it.
struct DivideEntry {
  Move move;
  std::uint64_t nodes;
};

/// For each legal root move, `perft(position after move, depth - 1)`, sorted
/// by the move's UCI string in ascending byte order. `depth` must be >= 1.
std::vector<DivideEntry> divide(const Position& pos, int depth);

}  // namespace chessperft

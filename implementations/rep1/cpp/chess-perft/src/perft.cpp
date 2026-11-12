#include "chessperft/perft.hpp"

#include <algorithm>
#include <string>
#include <utility>

#include "chessperft/movegen.hpp"

namespace chessperft {

std::uint64_t perft(const Position& pos, int depth) {
  if (depth <= 0) return 1;
  MoveList moves;
  generateLegalMoves(pos, moves);
  if (depth == 1) return moves.size();  // bulk counting
  std::uint64_t nodes = 0;
  for (const Move m : moves) {
    Position child = pos;
    child.makeMove(m);
    nodes += perft(child, depth - 1);
  }
  return nodes;
}

std::vector<DivideEntry> divide(const Position& pos, int depth) {
  std::vector<std::pair<std::string, DivideEntry>> keyed;
  for (const Move m : legalMoves(pos)) {
    Position child = pos;
    child.makeMove(m);
    keyed.push_back({m.toUci(), {m, perft(child, depth - 1)}});
  }
  std::sort(keyed.begin(), keyed.end(),
            [](const auto& a, const auto& b) { return a.first < b.first; });
  std::vector<DivideEntry> result;
  result.reserve(keyed.size());
  for (auto& k : keyed) result.push_back(k.second);
  return result;
}

}  // namespace chessperft

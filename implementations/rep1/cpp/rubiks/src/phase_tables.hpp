// Private header: the four phases (move set, coordinate, goal) and their
// exact distance tables.
#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "coordinates.hpp"

namespace rubiks::detail {

/// One Thistlethwaite phase: the moves it may use, how to read its
/// coordinate off a cube, how a move changes the coordinate, and the exact
/// number of moves to the goal for every coordinate (0xFF = unreachable).
class Phase {
 public:
  static constexpr std::uint8_t kUnreachable = 0xFF;

  /// Build phase `index` (0..3) and fill its distance table by BFS.
  explicit Phase(int index);

  int index() const { return index_; }
  const std::vector<Move>& moves() const { return moves_; }
  std::size_t size() const { return dist_.size(); }
  int maxDistance() const { return maxDistance_; }

  std::size_t coordinate(const CubieCube& c) const;
  std::size_t next(std::size_t coord, Move m) const;
  std::uint8_t distance(std::size_t coord) const { return dist_[coord]; }

 private:
  int index_;
  std::vector<Move> moves_;
  std::vector<std::uint8_t> dist_;
  int maxDistance_ = 0;
  const Coordinates& coords_;
};

}  // namespace rubiks::detail

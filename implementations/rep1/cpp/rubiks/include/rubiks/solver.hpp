// rubiks/solver.hpp -- Thistlethwaite's four-phase solver.
#pragma once

#include <array>
#include <cstddef>
#include <memory>
#include <vector>

#include "rubiks/cubie.hpp"
#include "rubiks/move.hpp"

namespace rubiks {

/// A solution and how it splits across the four phases.
struct Solution {
  std::vector<Move> moves;
  std::array<std::size_t, 4> phaseLengths{};  ///< moves used in each phase
};

/// Solves any reachable cube in at most 7 + 10 + 13 + 15 = 45 moves.
///
/// The cube is walked down the chain G0 > G1 > G2 > G3 > {identity}:
///
///  1. all 18 moves until every edge is oriented (G1 = <U D L R F2 B2>);
///  2. without F/B quarter turns until corners are oriented and the E-slice
///     edges are in the E slice (G2 = <U D L2 R2 F2 B2>);
///  3. U/D turns and L2 R2 F2 B2 until the corners are in the half-turn
///     group's orbit and each slice holds its own edges (G3 = <half turns>);
///  4. half turns until solved.
///
/// Each phase uses an exact distance table over a small coordinate space,
/// filled once by breadth-first search in the constructor (a fraction of a
/// second); solving is then a greedy descent with no search. A Solver is
/// immutable after construction, so `solve` may be called concurrently.
class Solver {
 public:
  /// Builds the four distance tables.
  Solver();
  ~Solver();
  Solver(Solver&&) noexcept;
  Solver& operator=(Solver&&) noexcept;

  /// Moves that bring `cube` to the solved state.
  /// @throws std::invalid_argument if `cube` is not a reachable state
  ///         (see CubieCube::isValid()).
  Solution solve(const CubieCube& cube) const;

  /// Convenience: scramble a solved cube with `scramble`, then solve it.
  Solution solve(std::span<const Move> scramble) const;

  /// Largest distance-to-goal in phase `phase` (0..3), i.e. the worst case
  /// length of that phase: 7, 10, 13 and 15.
  int maxPhaseLength(int phase) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rubiks

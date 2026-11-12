#include "rubiks/solver.hpp"

#include <stdexcept>

#include "phase_tables.hpp"

namespace rubiks {

struct Solver::Impl {
  std::vector<detail::Phase> phases;
  Impl() {
    phases.reserve(4);
    for (int i = 0; i < 4; ++i) phases.emplace_back(i);
  }
};

Solver::Solver() : impl_(std::make_unique<Impl>()) {}
Solver::~Solver() = default;
Solver::Solver(Solver&&) noexcept = default;
Solver& Solver::operator=(Solver&&) noexcept = default;

Solution Solver::solve(const CubieCube& cube) const {
  if (!cube.isValid()) throw std::invalid_argument("cube is not a reachable state");
  Solution sol;
  CubieCube state = cube;
  for (int p = 0; p < 4; ++p) {
    const detail::Phase& phase = impl_->phases[p];
    std::size_t coord = phase.coordinate(state);
    std::uint8_t d = phase.distance(coord);
    if (d == detail::Phase::kUnreachable) throw std::logic_error("phase coordinate unreachable");
    while (d > 0) {
      bool stepped = false;
      for (Move m : phase.moves()) {
        std::size_t n = phase.next(coord, m);
        if (phase.distance(n) == d - 1) {
          state.apply(m);
          sol.moves.push_back(m);
          ++sol.phaseLengths[p];
          coord = n;
          --d;
          stepped = true;
          break;
        }
      }
      if (!stepped) throw std::logic_error("no descending move");
    }
  }
  if (!state.isSolved()) throw std::logic_error("solver finished on an unsolved cube");
  return sol;
}

Solution Solver::solve(std::span<const Move> scramble) const {
  CubieCube c;
  c.apply(scramble);
  return solve(c);
}

int Solver::maxPhaseLength(int phase) const { return impl_->phases.at(phase).maxDistance(); }

}  // namespace rubiks

#include "phase_tables.hpp"

#include <stdexcept>

namespace rubiks::detail {

namespace {

std::vector<Move> movesFor(int phase) {
  std::vector<Move> v;
  for (int i = 0; i < kMoveCount; ++i) {
    Move m = Move::fromIndex(i);
    bool ud = m.face() == Face::U || m.face() == Face::D;
    bool fb = m.face() == Face::F || m.face() == Face::B;
    bool ok = false;
    switch (phase) {
      case 0: ok = true; break;                      // all 18
      case 1: ok = !fb || m.isHalfTurn(); break;     // no F/B quarter turns
      case 2: ok = ud || m.isHalfTurn(); break;      // U/D turns + L2 R2 F2 B2
      case 3: ok = m.isHalfTurn(); break;            // half turns only
    }
    if (ok) v.push_back(m);
  }
  return v;
}

}  // namespace

Phase::Phase(int index) : index_(index), moves_(movesFor(index)), coords_(Coordinates::instance()) {
  std::size_t goal = 0;
  switch (index) {
    case 0: dist_.assign(kEdgeOriCount, kUnreachable); goal = 0; break;
    case 1:
      dist_.assign(kCornerOriCount * kESliceCount, kUnreachable);
      goal = coords_.eSliceSolved();  // corner orientation 0 has index 0
      break;
    case 2:
      dist_.assign(kCornerClassCount * kMSliceCount, kUnreachable);
      goal = coords_.cornerClassSolved() * kMSliceCount + coords_.mSliceSolved();
      break;
    case 3:
      dist_.assign(kCornerPermCount * kSlicePermCount * kSlicePermCount * kSlicePermCount, kUnreachable);
      goal = 0;  // identity corner permutation and identity slice permutations
      break;
    default: throw std::invalid_argument("phase index");
  }

  // The move set of every phase is closed under inverses, so a forward BFS
  // from the goal yields distances *to* the goal.
  std::vector<std::uint32_t> frontier{static_cast<std::uint32_t>(goal)}, nextFrontier;
  dist_[goal] = 0;
  for (int d = 0; !frontier.empty(); ++d) {
    maxDistance_ = d;
    nextFrontier.clear();
    for (std::uint32_t s : frontier)
      for (Move m : moves_) {
        std::size_t n = next(s, m);
        if (dist_[n] == kUnreachable) {
          dist_[n] = static_cast<std::uint8_t>(d + 1);
          nextFrontier.push_back(static_cast<std::uint32_t>(n));
        }
      }
    frontier.swap(nextFrontier);
  }
}

std::size_t Phase::coordinate(const CubieCube& c) const {
  switch (index_) {
    case 0: return coords_.edgeOri(c);
    case 1: return coords_.cornerOri(c) * kESliceCount + coords_.eSlice(c);
    case 2: return coords_.cornerClass(c) * kMSliceCount + coords_.mSlice(c);
    default: {
      std::size_t v = coords_.cornerPerm(c);
      for (int s = 0; s < 3; ++s) v = v * kSlicePermCount + coords_.slicePerm(c, s);
      return v;
    }
  }
}

std::size_t Phase::next(std::size_t coord, Move m) const {
  switch (index_) {
    case 0: return coords_.edgeOriMove(coord, m);
    case 1: {
      std::size_t co = coord / kESliceCount, sl = coord % kESliceCount;
      return coords_.cornerOriMove(co, m) * kESliceCount + coords_.eSliceMove(sl, m);
    }
    case 2: {
      std::size_t cc = coord / kMSliceCount, ms = coord % kMSliceCount;
      return coords_.cornerClassMove(cc, m) * kMSliceCount + coords_.mSliceMove(ms, m);
    }
    default: {
      std::size_t s2 = coord % kSlicePermCount; coord /= kSlicePermCount;
      std::size_t s1 = coord % kSlicePermCount; coord /= kSlicePermCount;
      std::size_t s0 = coord % kSlicePermCount; coord /= kSlicePermCount;
      std::size_t v = coords_.cornerPermMove(coord, m);
      v = v * kSlicePermCount + coords_.slicePermMove(0, s0, m);
      v = v * kSlicePermCount + coords_.slicePermMove(1, s1, m);
      v = v * kSlicePermCount + coords_.slicePermMove(2, s2, m);
      return v;
    }
  }
}

}  // namespace rubiks::detail

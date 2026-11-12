// Private header: the coordinate spaces of the four Thistlethwaite phases and
// the move tables that act on them.
//
//   phase 1  edge orientation (11 bits)                         2048
//   phase 2  corner orientation (7 trits) x E-slice positions   2187 x 495
//   phase 3  corner coset mod the half-turn group x M-slice     420 x 70
//   phase 4  corner perm in half-turn group x 3 slice perms     96 x 24^3
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "rubiks/cubie.hpp"
#include "rubiks/move.hpp"

namespace rubiks::detail {

inline constexpr std::size_t kEdgeOriCount = 2048;
inline constexpr std::size_t kCornerOriCount = 2187;
inline constexpr std::size_t kESliceCount = 495;
inline constexpr std::size_t kCornerClassCount = 420;
inline constexpr std::size_t kMSliceCount = 70;
inline constexpr std::size_t kCornerPermCount = 96;
inline constexpr std::size_t kSlicePermCount = 24;

/// Coordinate extraction and per-coordinate move tables. Built once.
/// Every move table is indexed `[coordinate * 18 + move.index()]`; entries for
/// moves outside the phase that uses the coordinate are left at 0xFFFF.
class Coordinates {
 public:
  static const Coordinates& instance();

  // --- phase 1 ---
  std::size_t edgeOri(const CubieCube& c) const;
  std::size_t edgeOriMove(std::size_t coord, Move m) const { return edgeOriMove_[coord * kMoveCount + m.index()]; }

  // --- phase 2 ---
  std::size_t cornerOri(const CubieCube& c) const;
  std::size_t eSlice(const CubieCube& c) const;
  std::size_t cornerOriMove(std::size_t coord, Move m) const { return cornerOriMove_[coord * kMoveCount + m.index()]; }
  std::size_t eSliceMove(std::size_t coord, Move m) const { return eSliceMove_[coord * kMoveCount + m.index()]; }
  std::size_t eSliceSolved() const { return eSliceSolved_; }

  // --- phase 3 ---
  std::size_t cornerClass(const CubieCube& c) const;
  std::size_t mSlice(const CubieCube& c) const;
  std::size_t cornerClassMove(std::size_t coord, Move m) const { return cornerClassMove_[coord * kMoveCount + m.index()]; }
  std::size_t mSliceMove(std::size_t coord, Move m) const { return mSliceMove_[coord * kMoveCount + m.index()]; }
  std::size_t cornerClassSolved() const { return cornerClassSolved_; }
  std::size_t mSliceSolved() const { return mSliceSolved_; }

  // --- phase 4 ---
  std::size_t cornerPerm(const CubieCube& c) const;       // index in the 96-element group
  std::size_t slicePerm(const CubieCube& c, int slice) const;  // slice 0 = M, 1 = S, 2 = E
  std::size_t cornerPermMove(std::size_t coord, Move m) const { return cornerPermMove_[coord * kMoveCount + m.index()]; }
  std::size_t slicePermMove(int slice, std::size_t coord, Move m) const {
    return slicePermMove_[(slice * kSlicePermCount + coord) * kMoveCount + m.index()];
  }
  std::size_t cornerPermSolved() const { return cornerPermSolved_; }

 private:
  Coordinates();

  std::size_t cornerRank(const CubieCube& c) const;

  std::array<std::uint16_t, 4096> mask12ToIndex_{};   // 4-subsets of 12 positions
  std::array<std::uint16_t, 256> mask8ToIndex_{};     // 4-subsets of 8 positions
  std::vector<std::uint16_t> indexToMask12_, indexToMask8_;
  std::vector<std::int16_t> classOfPerm_;             // 8! -> 0..419
  std::vector<std::int16_t> groupIndexOfPerm_;        // 8! -> 0..95 or -1

  std::vector<std::uint16_t> edgeOriMove_, cornerOriMove_, eSliceMove_;
  std::vector<std::uint16_t> cornerClassMove_, mSliceMove_;
  std::vector<std::uint16_t> cornerPermMove_, slicePermMove_;
  std::size_t eSliceSolved_ = 0, cornerClassSolved_ = 0, mSliceSolved_ = 0, cornerPermSolved_ = 0;
};

}  // namespace rubiks::detail

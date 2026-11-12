// rubiks/cubie.hpp -- the cubie-level cube model (permutations + orientations).
#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <span>

#include "rubiks/facelet.hpp"
#include "rubiks/move.hpp"

namespace rubiks {

/// Corner positions/cubies, numbered as in SPEC.md's corner list:
/// 0 URF (U9 R1 F3), 1 UFL, 2 ULB, 3 UBR, 4 DFR, 5 DLF, 6 DBL, 7 DRB.
/// Edge positions/cubies: 0 UR, 1 UF, 2 UL, 3 UB, 4 DR, 5 DF, 6 DL, 7 DB,
/// 8 FR, 9 FL, 10 BL, 11 BR (the SPEC.md edge order).
///
/// A CubieCube records, for every position, which cubie sits there and how it
/// is turned:
///  * `co[p]` is the index (0..2) within position p's facelet triple of the
///    sticker showing the cubie's first (U/D) colour;
///  * `eo[p]` is 0 if the cubie's first colour is on position p's first
///    facelet, else 1. For the four slice edges 8..11 the first colour is the
///    F/B one, so quarter turns of F and B are the only moves that flip edges.
struct CubieCube {
  std::array<std::uint8_t, 8> cp{0, 1, 2, 3, 4, 5, 6, 7};
  std::array<std::uint8_t, 8> co{};
  std::array<std::uint8_t, 12> ep{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
  std::array<std::uint8_t, 12> eo{};

  /// Apply one move (the cube is turned further, starting from its state).
  void apply(Move move);
  void apply(std::span<const Move> moves);

  bool isSolved() const;

  /// True when this is a reachable state: both are permutations, twists sum
  /// to 0 mod 3, flips sum to 0 mod 2, and the permutation parities agree.
  bool isValid() const;

  /// Sticker-level view of this cube.
  FaceletCube toFacelets() const;

  /// Recover the cubies from stickers; nullopt unless the stickers form eight
  /// corners and twelve edges (it does not check solvability; see isValid()).
  static std::optional<CubieCube> fromFacelets(const FaceletCube& cube);

  friend bool operator==(const CubieCube&, const CubieCube&) = default;
};

}  // namespace rubiks

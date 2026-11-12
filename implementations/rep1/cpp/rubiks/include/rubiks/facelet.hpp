// rubiks/facelet.hpp -- the sticker-level cube model defined by SPEC.md.
#pragma once

#include <array>
#include <optional>
#include <span>
#include <string>
#include <string_view>

#include "rubiks/move.hpp"

namespace rubiks {

inline constexpr int kFaceletCount = 54;

/// Name of facelet `index` in the library's numbering: faces in the order
/// U R F D L B, nine stickers each in reading order ("U1".."B9").
std::string faceletName(int index);

/// Index of a facelet from its name ("R7" -> 15); nullopt if invalid.
std::optional<int> faceletIndex(std::string_view name);

/// For a basic move, `src[i]` is the facelet whose sticker lands on facelet
/// `i` after the move (a permutation of 0..53).
const std::array<int, kFaceletCount>& faceletSource(Move move);

/// A cube described by the colour of each of its 54 stickers. A colour is
/// named by the face whose centre carries it.
class FaceletCube {
 public:
  /// The solved cube.
  FaceletCube();

  /// Parse 54 characters from "URFDLB", one per facelet in library order.
  static std::optional<FaceletCube> fromString(std::string_view s);

  Face at(int facelet) const { return stickers_[facelet]; }
  const std::array<Face, kFaceletCount>& stickers() const { return stickers_; }

  void apply(Move move);
  void apply(std::span<const Move> moves);

  /// True when every sticker matches the centre of its face.
  bool isSolved() const;

  /// 54-character encoding, inverse of fromString.
  std::string toString() const;

  friend bool operator==(const FaceletCube&, const FaceletCube&) = default;

 private:
  std::array<Face, kFaceletCount> stickers_;
};

}  // namespace rubiks

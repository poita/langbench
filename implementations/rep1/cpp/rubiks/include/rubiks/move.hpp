// rubiks/move.hpp -- the eighteen face moves and their text notation.
#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace rubiks {

/// The six faces, in the order used throughout the library.
enum class Face : std::uint8_t { U, R, F, D, L, B };

inline constexpr int kFaceCount = 6;
inline constexpr int kMoveCount = 18;

/// One of the eighteen moves: a face turned by 1 (clockwise), 2 (half turn)
/// or 3 (counter-clockwise) quarter turns, as seen from outside the cube.
///
/// A Move is a small value type whose `index()` (0..17) is
/// `3 * face + (turns - 1)`; it is suitable for indexing tables.
class Move {
 public:
  constexpr Move() = default;
  constexpr Move(Face face, int turns)
      : index_(static_cast<std::uint8_t>(static_cast<int>(face) * 3 + (turns - 1))) {}

  /// Construct from an index in [0, 18).
  static constexpr Move fromIndex(int index) {
    Move m;
    m.index_ = static_cast<std::uint8_t>(index);
    return m;
  }

  constexpr Face face() const { return static_cast<Face>(index_ / 3); }
  /// Number of clockwise quarter turns: 1, 2 or 3.
  constexpr int turns() const { return index_ % 3 + 1; }
  constexpr int index() const { return index_; }
  constexpr bool isHalfTurn() const { return index_ % 3 == 1; }

  /// The move that undoes this one (`R` <-> `R'`, `R2` -> `R2`).
  constexpr Move inverse() const { return Move(face(), 4 - turns()); }

  /// Notation: "U", "U'", "U2", ...
  std::string_view str() const;

  friend constexpr bool operator==(Move a, Move b) { return a.index_ == b.index_; }
  friend constexpr bool operator!=(Move a, Move b) { return a.index_ != b.index_; }

 private:
  std::uint8_t index_ = 0;
};

/// Parse a single token such as "R", "R'" or "R2"; nullopt if malformed.
std::optional<Move> parseMove(std::string_view token);

/// Parse whitespace-separated tokens, appending to `out`.
/// Returns false (leaving `out` partially filled) on the first bad token.
bool parseMovesInto(std::string_view text, std::vector<Move>& out);

/// Parse a whole sequence; nullopt if any token is malformed.
std::optional<std::vector<Move>> parseMoves(std::string_view text);

/// Format a sequence with single spaces between tokens ("" if empty).
std::string toString(std::span<const Move> moves);

/// The sequence that undoes `moves`.
std::vector<Move> inverse(std::span<const Move> moves);

}  // namespace rubiks

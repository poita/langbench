// Version ranges: "*", exact, caret, tilde and comparator sets.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "depresolve/version.hpp"

namespace depresolve {

/// A set of versions expressed as a half-open interval [lower, upper).
///
/// Every supported range syntax (npm caret/tilde semantics, comparators,
/// exact versions and `*`) denotes such an interval, and the intersection of
/// intervals is again an interval, which is what makes binary search over a
/// sorted version list possible.
class Range {
 public:
  /// The range `*`: accepts every version.
  Range() = default;

  /// Accepts v with lower <= v < upper. May be empty (lower >= upper).
  Range(Version lower, Version upper) : lower_(lower), upper_(upper) {}

  static Range any() { return Range(); }
  /// `X.Y.Z`: exactly one version.
  static Range exact(Version v) { return Range(v, v.successor()); }
  /// `^X.Y.Z`: keeps the leftmost non-zero component fixed.
  static Range caret(Version v);
  /// `~X.Y.Z`: keeps major and minor fixed.
  static Range tilde(Version v);
  /// `>=lo`.
  static Range at_least(Version lo) { return Range(lo, Version::max()); }
  /// `>lo`.
  static Range greater_than(Version lo) { return at_least(lo.successor()); }
  /// `<hi`.
  static Range less_than(Version hi) { return Range(Version{}, hi); }
  /// `<=hi`.
  static Range at_most(Version hi) { return less_than(hi.successor()); }

  /// Parses the textual form used in registry files, e.g. `^1.2.3`,
  /// `>=1.0.0 <2.0.0`, `*`. Returns std::nullopt on malformed input.
  static std::optional<Range> parse(std::string_view text);

  bool contains(const Version& v) const noexcept { return lower_ <= v && v < upper_; }
  /// True when no version can satisfy the range.
  bool empty() const noexcept { return !(lower_ < upper_); }
  /// The intersection of two ranges (all comparators must hold).
  Range intersect(const Range& other) const noexcept;

  const Version& lower() const noexcept { return lower_; }
  /// Exclusive upper bound.
  const Version& upper() const noexcept { return upper_; }

  friend bool operator==(const Range&, const Range&) = default;

 private:
  Version lower_{};
  Version upper_ = Version::max();
};

}  // namespace depresolve

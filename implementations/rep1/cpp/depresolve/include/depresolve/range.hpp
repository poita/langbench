/// \file range.hpp
/// Version ranges with npm caret/tilde semantics, normalised to a half-open
/// interval of versions.
#pragma once

#include <optional>
#include <string_view>

#include "depresolve/version.hpp"

namespace depresolve {

/// The set of versions `v` with `lo() <= v < hi()`.
///
/// Every supported range syntax (`*`, exact, `^`, `~`, and conjunctions of
/// `<`, `<=`, `>`, `>=` comparators) denotes such an interval, possibly empty.
class Range {
 public:
  /// Matches every version.
  static Range any();
  /// Matches exactly `v`.
  static Range exact(const Version& v);
  /// npm caret: keeps the leftmost non-zero component fixed.
  static Range caret(const Version& v);
  /// npm tilde: keeps major and minor fixed.
  static Range tilde(const Version& v);
  /// Matches `lo <= v < hi` (empty when `lo >= hi`).
  static Range between(const Version& lo, const Version& hi);

  /// Parses the `range` grammar of SPEC.md: `*`, `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z`
  /// or one to three space-separated comparators such as `>=1.0.0 <2.0.0`.
  /// Returns nullopt when the text is not a valid range.
  static std::optional<Range> parse(std::string_view text);

  /// Inclusive lower bound.
  const Version& lo() const { return lo_; }
  /// Exclusive upper bound (a very large sentinel version when unbounded).
  const Version& hi() const { return hi_; }

  /// True when no version can satisfy the range.
  bool empty() const { return !(lo_ < hi_); }
  /// True when `v` satisfies the range.
  bool contains(const Version& v) const { return lo_ <= v && v < hi_; }

 private:
  Range(const Version& lo, const Version& hi) : lo_(lo), hi_(hi) {}
  Version lo_;
  Version hi_;
};

}  // namespace depresolve

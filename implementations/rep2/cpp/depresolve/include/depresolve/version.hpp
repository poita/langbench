// Semantic versions (MAJOR.MINOR.PATCH, no prerelease/build metadata).
#pragma once

#include <compare>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace depresolve {

/// One numeric component of a version.
using Component = std::uint32_t;

/// Largest component value accepted by Version::parse(). Keeping one value in
/// reserve lets Version::successor() and the caret/tilde upper bounds be
/// computed without overflow.
inline constexpr Component kMaxComponent = 0xFFFFFFFEu;

/// A three-component version. Ordering is numeric, component by component
/// (major first), so 1.10.0 is newer than 1.9.0.
struct Version {
  Component major = 0;
  Component minor = 0;
  Component patch = 0;

  friend constexpr auto operator<=>(const Version&, const Version&) = default;

  /// A version greater than every parsable version; used as an open upper bound.
  static constexpr Version max() noexcept {
    return {~Component{0}, ~Component{0}, ~Component{0}};
  }

  /// The smallest version strictly greater than *this (patch + 1).
  constexpr Version successor() const noexcept { return {major, minor, patch + 1}; }

  /// Parses "X.Y.Z" (decimal, no leading zeros, no whitespace). Returns
  /// std::nullopt when `text` is not exactly that.
  static std::optional<Version> parse(std::string_view text) noexcept;

  /// Formats as "X.Y.Z".
  std::string to_string() const;
};

}  // namespace depresolve

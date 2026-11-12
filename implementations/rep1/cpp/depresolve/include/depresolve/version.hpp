/// \file version.hpp
/// Semantic versions (MAJOR.MINOR.PATCH, no prerelease/build suffixes).
#pragma once

#include <compare>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace depresolve {

/// Largest version component accepted by Version::parse.
inline constexpr std::uint32_t kMaxVersionComponent = 1'000'000'000;

/// A three-component version. Ordering is numeric, major first
/// (so 1.10.0 > 1.9.0).
struct Version {
  std::uint32_t major = 0;
  std::uint32_t minor = 0;
  std::uint32_t patch = 0;

  friend constexpr auto operator<=>(const Version&, const Version&) = default;

  /// Parses `num "." num "." num` where num is `0` or has no leading zeros.
  /// Returns nullopt on any deviation (including components over
  /// kMaxVersionComponent).
  static std::optional<Version> parse(std::string_view text);

  /// Formats as "MAJOR.MINOR.PATCH".
  std::string to_string() const;
};

}  // namespace depresolve

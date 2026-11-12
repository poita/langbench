// toml/number.hpp - integer and float literals, handled as canonical text.
#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace toml {

/// Validates a TOML integer literal (decimal, 0x, 0o or 0b; underscores
/// allowed between digits) and returns its canonical decimal text, e.g.
/// "0xFF" -> "255". Returns nullopt if the literal is malformed or does not
/// fit a signed 64-bit integer.
std::optional<std::string> canonical_integer(std::string_view literal);

/// Validates a TOML float literal (including `inf` and `nan` with optional
/// sign) and returns its canonical text as produced by `format_float`.
/// Out-of-range magnitudes become infinity or zero, as with `strtod`.
std::optional<std::string> canonical_float(std::string_view literal);

/// Canonical text for a double: "nan", "inf", "-inf", or exactly 17
/// significant digits in scientific notation (`%.16e`).
std::string format_float(double v);

}  // namespace toml

// toml/datetime.hpp - RFC 3339 style date/time literals, handled as text.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "toml/value.hpp"

namespace toml {

struct DateTimeLiteral {
  Type type;            ///< DateTime, DateTimeLocal, DateLocal or TimeLocal
  std::string text;     ///< canonical text
  std::size_t length;   ///< number of input bytes the literal occupies
};

/// Scans a date/time literal at the start of `input`. Validates field widths
/// and ranges (real calendar dates, no leap seconds) without any date
/// arithmetic library and returns the canonical text: uppercase `T`, `Z` for
/// zero offsets, trailing zeros removed from fractional seconds. Returns
/// nullopt when `input` does not start with a valid literal.
std::optional<DateTimeLiteral> scan_datetime(std::string_view input);

}  // namespace toml

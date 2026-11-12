// Date header parsing and calendar arithmetic.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace mime {

struct ParsedDate {
  std::int64_t epoch;      ///< seconds since 1970-01-01T00:00:00Z
  int offset_minutes;      ///< zone offset as written
  std::string utc;         ///< YYYY-MM-DDTHH:MM:SSZ
  std::string offset;      ///< e.g. +0200
};

/// Days from 1970-01-01 to the given proleptic Gregorian date.
std::int64_t days_from_civil(std::int64_t y, unsigned m, unsigned d);

/// Inverse of days_from_civil.
void civil_from_days(std::int64_t z, std::int64_t& y, unsigned& m, unsigned& d);

/// Parses a raw Date value; nullopt if it is not a valid date.
std::optional<ParsedDate> parse_date(std::string_view raw);

}  // namespace mime

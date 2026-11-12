// Text parsing for DTSTART values and RRULE strings.
#pragma once

#include <stdexcept>
#include <string>
#include <string_view>

#include "rrule/rule.hpp"

namespace rrule {

/// Thrown when text cannot be parsed.
class ParseError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Parses `YYYYMMDDTHHMMSS`. Throws ParseError on malformed or out-of-range
/// input (including non-existent calendar dates).
DateTime parse_datetime(std::string_view text);

/// Parses an RRULE value such as `FREQ=MONTHLY;BYDAY=-1FR;COUNT=10`.
/// Throws ParseError on unknown parts, bad values or a missing FREQ. Only
/// syntax and value ranges are checked, not the cross-part restrictions of
/// RFC 5545.
Rule parse_rule(std::string_view text);

}  // namespace rrule

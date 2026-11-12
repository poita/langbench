// Text front end: evaluate "<op> <a> <b>" / "sqrt <a>" lines of hex bit patterns.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "softfloat/bits.h"

namespace softfloat {

/// Evaluate one operation line such as "add 3f800000 3f800000" or "sqrt 40000000".
/// Returns nullopt if the line is malformed (unknown op, wrong arity, bad hex).
std::optional<Bits32> evaluate_line(std::string_view line);

/// Format a pattern as exactly 8 lowercase hex digits.
std::string format_bits(Bits32 x);

/// Evaluate every line of `input` (a trailing '\r' on a line is ignored; the last
/// line may lack '\n') and return one output line per input line, each ending in '\n'.
/// On a malformed line returns nullopt and stores its 1-based number in *bad_line
/// (if non-null).
std::optional<std::string> evaluate_all(std::string_view input, std::size_t* bad_line = nullptr);

}  // namespace softfloat

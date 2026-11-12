#pragma once
/// \file format.hpp
/// Conversion of values to text, as done by `{{ }}`, `~` and string filters.

#include <string>

#include "jinjalite/value.hpp"

namespace jinjalite {

/// Shortest round-trip decimal form of `d`, laid out like Python's `repr`
/// (`3.0`, `0.0001`, `1e+16`, `1e-05`, `-0.0`).
std::string format_float(double d);

/// Appends the printed form of `v` to `out`. Throws `Error(Undefined)` for
/// the undefined value.
void append_display(std::string& out, const Value& v);

/// Appends the repr of `v` (strings quoted) to `out`; used for list/dict
/// elements.
void append_repr(std::string& out, const Value& v);

/// The printed form of `v` as a new string.
std::string to_display(const Value& v);

}  // namespace jinjalite

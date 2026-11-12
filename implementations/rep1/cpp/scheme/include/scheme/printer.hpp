/// \file printer.hpp
/// Value output in `write` and `display` forms.
#pragma once

#include <iosfwd>
#include <string>

#include "scheme/value.hpp"

namespace scheme {

/// Append the external representation of `v` to `out`.
/// With `display` true, strings are emitted raw (no quotes or escapes).
void print_value(std::string& out, const Value& v, bool display);

/// The `write` form of `v`.
std::string write_string(const Value& v);
/// The `display` form of `v`.
std::string display_string(const Value& v);

}  // namespace scheme

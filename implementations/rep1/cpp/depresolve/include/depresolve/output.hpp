/// \file output.hpp
/// Rendering of resolution results in the CLI's output format.
#pragma once

#include <optional>
#include <string>

#include "depresolve/resolver.hpp"

namespace depresolve {

/// "name version\n" per package in the given (name-sorted) order, or exactly
/// "unsatisfiable\n" when `result` is empty (no resolution exists).
/// A resolution of zero packages renders as the empty string.
std::string format_resolution(const std::optional<Resolution>& result);

}  // namespace depresolve

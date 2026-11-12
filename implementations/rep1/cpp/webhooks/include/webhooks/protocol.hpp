/// @file protocol.hpp
/// The line-oriented command language of SPEC.md §3-§4, as a pure function.
#pragma once

#include <string>
#include <string_view>

namespace webhooks {

/// Executes every command in @p input (the whole of stdin) and returns the
/// whole output. Each command line yields one output line (or, for `simulate`,
/// a block); malformed input yields the single word `error`, never an exception.
/// Blank lines (empty or only spaces) are ignored.
std::string run_commands(std::string_view input);

}  // namespace webhooks

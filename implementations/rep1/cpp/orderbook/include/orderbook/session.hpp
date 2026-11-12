#pragma once
/// @file session.hpp
/// Runs a whole command stream (the SPEC.md input format) against a fresh book.

#include <cstddef>
#include <ostream>
#include <string>
#include <string_view>

namespace orderbook {

/// Outcome of run_session().
struct SessionResult {
  bool ok = true;              ///< false if the input was malformed
  std::size_t commands = 0;    ///< commands executed
  std::string error;           ///< description when !ok
};

/// Process `input` — a line holding N followed by N command lines (the final
/// newline is optional) — executing each command on a new OrderBook and
/// writing the textual events to `out`. Stops at the first malformed line.
/// If fewer than N command lines are present, the ones present are run.
SessionResult run_session(std::string_view input, std::ostream& out);

}  // namespace orderbook

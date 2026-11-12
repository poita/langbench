// Batch driver implementing the line-oriented I/O contract of the CLI.
#pragma once

#include <iosfwd>
#include <string>
#include <string_view>

#include "rx/error.hpp"
#include "rx/matcher.hpp"

namespace rx {

/// Thrown for malformed batch input (truncated, bad counts, bad pattern).
class BatchError : public Error {
 public:
  using Error::Error;
};

/// Appends the one-line report for a search result to `out`:
/// `no`, or `match <b> <e>` followed by `|<gs>,<ge>` / `|-` per group,
/// then '\n'.
void format_result(bool matched, const Match& m, std::string& out);

/// Processes a whole batch:
///   N, then per pattern: pattern line, M, M subject lines.
/// Writes one result line per subject to `out`.
/// \throws BatchError on malformed input.
void run_batch(std::string_view input, std::ostream& out);

}  // namespace rx

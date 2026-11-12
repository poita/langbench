#pragma once
/// \file batch.hpp
/// The batch protocol of the command-line tool: patterns with subject lists
/// in, one result line per subject out.

#include <iosfwd>
#include <stdexcept>

namespace regex {

/// Malformed batch input.
class BatchError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Reads the batch from \p in and writes one line per subject to \p out:
/// `no`, or `match <start> <end>` followed by `|<begin>,<end>` / `|-` for each
/// capture group. Throws BatchError or ParseError on bad input.
void run_batch(std::istream& in, std::ostream& out);

}  // namespace regex

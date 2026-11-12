// Runs a whole match file: setup, script and output.
#pragma once

#include <iosfwd>
#include <string>

namespace spiremark {

/// Processes a complete match file (SPEC.md section 4) and writes the log to
/// `out`. Never throws for bad input: setup problems become a single
/// `FATAL ...` line, rejected actions become `ERR` lines.
void run_match(const std::string& input, std::ostream& out);

}  // namespace spiremark

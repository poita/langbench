// High-level diff of text lines.
#pragma once

#include "mdiff/lines.hpp"
#include "mdiff/script.hpp"

namespace mdiff {

/// Computes a minimal edit script turning `a` into `b` (lines compared
/// byte-for-byte). Interns the lines, then runs the linear-space Myers search.
EditScript diff_lines(const Lines& a, const Lines& b);

}  // namespace mdiff

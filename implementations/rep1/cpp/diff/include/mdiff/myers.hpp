// Myers' O(ND) difference algorithm, linear-space (middle snake) variant.
#pragma once

#include <cstddef>
#include <vector>

#include "mdiff/lines.hpp"
#include "mdiff/script.hpp"

namespace mdiff {

/// Computes a shortest edit script between two sequences of line ids.
///
/// Implements E. Myers, "An O(ND) Difference Algorithm and Its Variations"
/// (1986), section 4b: the middle snake of an optimal path is found by
/// searching forward and backward simultaneously, then the two halves are
/// solved recursively. Time is O((N+M)·D) and extra space O(N+M); recursion
/// depth is O(log D). Common prefixes and suffixes are trimmed at every level.
///
/// The result has Keep/Delete edits indexing into `a` and Insert edits
/// indexing into `b`, in script order; its cost is exactly N + M - 2·LCS.
EditScript myers_diff(const std::vector<LineId>& a, const std::vector<LineId>& b);

}  // namespace mdiff

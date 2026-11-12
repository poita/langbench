// The depth-first, newest-first, chronologically backtracking resolver.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "depresolve/parser.hpp"
#include "depresolve/registry.hpp"
#include "depresolve/version.hpp"

namespace depresolve {

/// One chosen package version.
struct Pick {
  std::string name;
  Version version;
};

/// Counters describing the work done by one search.
struct SearchStats {
  std::uint64_t steps = 0;         ///< pending requirements processed
  std::uint64_t choice_points = 0;  ///< candidate versions tried
};

/// Outcome of a resolution.
struct Resolution {
  bool satisfiable = false;
  /// Chosen versions sorted by name in ascending byte order (empty when not
  /// satisfiable, or when the root needs nothing).
  std::vector<Pick> picks;
  SearchStats stats;
};

/// Runs the search from SPEC.md: requirements are processed depth-first in
/// the order listed, a newly chosen version's requirements go in front of the
/// remaining ones, candidates are tried newest first, and failure backtracks
/// chronologically. The first complete solution found is returned.
///
/// Each step is O(1) plus the requirements it pushes: choices are undone
/// through an explicit stack, pending requirements form a shared linked list
/// in an arena, and candidates are the precompiled index ranges. The search
/// is iterative so recursion depth is not limited by the call stack.
///
/// @pre registry.finalized()
Resolution resolve(const Registry& registry, const std::vector<Requirement>& root);

/// Compiles `root` against `registry` and resolves it.
Resolution resolve(const Registry& registry, const std::vector<Dependency>& root);

/// Convenience overload for a parsed problem.
inline Resolution resolve(const Problem& problem) {
  return resolve(problem.registry, problem.root);
}

/// Renders a resolution as in SPEC.md: "name version\n" per pick, or
/// "unsatisfiable\n".
std::string format_resolution(const Resolution& resolution);

/// Parses `input` (registry lines + root line) and returns the formatted
/// resolution. @throws ParseError on malformed input.
std::string resolve_text(std::string_view input);

}  // namespace depresolve

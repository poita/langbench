/// \file resolver.hpp
/// The dependency resolver: SPEC.md's depth-first, newest-first,
/// chronologically backtracking search.
#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include "depresolve/parser.hpp"
#include "depresolve/registry.hpp"

namespace depresolve {

/// A package pinned to one version.
struct ResolvedPackage {
  std::string name;
  Version version;
};

/// A successful resolution: one entry per chosen package, sorted by name
/// (ascending byte order).
struct Resolution {
  std::vector<ResolvedPackage> packages;
};

/// Counters describing the work done by the last Resolver::resolve call.
struct ResolveStats {
  std::uint64_t choices = 0;  ///< versions tried (search steps that pick a version)
};

/// Resolves root requirements against a registry.
///
/// Construction precomputes, for every package, its versions sorted newest
/// first, and for every requirement the contiguous index range of candidates
/// it admits. resolve() then runs the search with an explicit stack: chosen
/// versions are undone through a trail and the pending requirements form a
/// persistent linked list shared between choice points, so a step costs O(1)
/// plus the requirements it adds, and recursion depth is not limited by the
/// call stack.
///
/// All needed data is copied, so the Registry need not outlive the Resolver.
class Resolver {
 public:
  Resolver(const Registry& registry, std::span<const Requirement> root);

  /// Runs the search. Returns the first solution in search order, or nullopt
  /// if none exists. May be called repeatedly; each call restarts the search.
  std::optional<Resolution> resolve();

  /// Statistics of the most recent resolve() call.
  const ResolveStats& stats() const { return stats_; }

 private:
  // A registry version in sorted position; its requirements are
  // creqs_[req_begin, req_end).
  struct Candidate {
    Version version;
    std::uint32_t req_begin;
    std::uint32_t req_end;
  };
  // A requirement with its admitted candidates cands_[lo, hi) (newest first).
  struct CompiledReq {
    PackageId package;
    std::uint32_t lo;
    std::uint32_t hi;
  };

  std::vector<std::string> names_;
  std::vector<Candidate> cands_;     // grouped by package, newest first within a group
  std::vector<CompiledReq> creqs_;   // root requirements first, then per candidate
  std::uint32_t root_count_ = 0;
  ResolveStats stats_;
};

/// Convenience: resolves a parsed problem.
std::optional<Resolution> resolve(const Problem& problem);

}  // namespace depresolve

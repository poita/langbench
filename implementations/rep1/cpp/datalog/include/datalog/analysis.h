// Static checks: rule safety and stratification.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "datalog/ast.h"
#include "datalog/predicates.h"

namespace datalog {

/// Returns a description of the first unsafe rule, or nullopt if every rule
/// is safe. A rule is safe when each variable of its head, of a negated atom
/// and of a comparison also occurs in a positive body atom; `_` in any of
/// those places is unsafe; a fact must be ground.
std::optional<std::string> find_unsafe_rule(const Program& program);

/// A partition of the predicates into strongly connected components of the
/// dependency graph, in evaluation order (dependencies first).
struct Stratification {
  /// components[i] lists the predicates of the i-th component.
  std::vector<std::vector<PredId>> components;
  /// component_of[p] is the index of p's component.
  std::vector<std::size_t> component_of;
};

/// Computes the stratification of `program`, or nullopt if some cycle of the
/// dependency graph contains a negative edge.
std::optional<Stratification> stratify(const Program& program, const PredicateTable& preds);

}  // namespace datalog

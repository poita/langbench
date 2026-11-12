// Semi-naive bottom-up evaluation of one component of the dependency graph.
#pragma once

#include <vector>

#include "datalog/plan.h"
#include "datalog/predicates.h"
#include "datalog/relation.h"

namespace datalog {

/// The compiled rules of one strongly connected component.
struct ComponentPlan {
  std::vector<PredId> predicates;
  /// One plan per rule, every atom reading the whole relation.
  std::vector<RulePlan> initial;
  /// One plan per (rule, recursive positive atom): the semi-naive variants.
  std::vector<RulePlan> delta;
};

/// Computes the least fixpoint of the component's rules over `relations`
/// (which must already hold the component's facts and complete lower
/// components): one round with `initial`, then rounds with `delta` until a
/// round adds no tuple. Each tuple is a delta in exactly one round.
void evaluate_component(const ComponentPlan& plan, std::vector<Relation>& relations);

}  // namespace datalog

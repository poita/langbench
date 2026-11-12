// Join plans: a rule compiled into an indexed nested-loop join.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

#include "datalog/ast.h"
#include "datalog/predicates.h"
#include "datalog/relation.h"
#include "datalog/value.h"

namespace datalog {

/// Where a value comes from at run time: a constant or a variable slot.
struct Source {
  bool is_slot = false;
  Value constant = 0;
  std::uint32_t slot = 0;
};

/// A filter applied as soon as all its variables are bound.
struct Filter {
  enum class Kind { Compare, NotIn };
  Kind kind = Kind::Compare;
  CompareOp op = CompareOp::Eq;  // Compare
  Source lhs, rhs;               // Compare
  PredId pred = 0;               // NotIn: negated atom's predicate...
  std::vector<Source> terms;     // ...and its arguments
};

struct ColumnBind { std::uint32_t column, slot; };
struct ColumnCheck { std::uint32_t column; Source expected; };

/// Which tuples of a relation a join step may read in the current round.
enum class StepRange {
  Full,   // everything that existed when the round started
  Old,    // only tuples older than the round's delta
  Delta   // only the previous round's new tuples
};

/// One positive body atom of the join.
struct JoinStep {
  PredId pred = 0;
  StepRange range = StepRange::Full;
  /// Index used to look up matching tuples, or null to scan the range.
  const Index* index = nullptr;
  /// Values of the index's key columns, in column order.
  std::vector<Source> key;
  /// Variables first bound by this atom.
  std::vector<ColumnBind> binds;
  /// Further conditions on a candidate tuple (constants when scanning,
  /// repeated variables within the atom).
  std::vector<ColumnCheck> checks;
  /// Filters that become evaluable after this step.
  std::vector<Filter> filters;
};

/// A compiled rule (or one semi-naive variant of a rule).
struct RulePlan {
  PredId head = 0;
  std::vector<Source> head_terms;
  std::vector<Filter> pre_filters;  // filters with no variables
  std::vector<JoinStep> steps;
  std::size_t num_slots = 0;
};

/// Everything compile_rule needs to know about its surroundings.
struct PlanContext {
  const PredicateTable& preds;
  const ValueEncoder& encoder;
  std::vector<Relation>& relations;  // indexed by PredId; indexes get created here
  /// True for predicates of the component being evaluated.
  std::function<bool(PredId)> in_component;
};

/// Compiles `rule`. With `delta_literal < 0` every atom reads the whole
/// relation. Otherwise the positive atom at body position `delta_literal` is
/// the delta atom: it is joined first and reads the previous round's new
/// tuples; component atoms before it read only older tuples, those after it
/// read everything. Join order afterwards: most bound arguments first, ties in
/// body order.
RulePlan compile_rule(const Rule& rule, int delta_literal, PlanContext& ctx);

}  // namespace datalog

#include "datalog/evaluator.h"

#include <algorithm>

namespace datalog {
namespace {

bool compare(CompareOp op, Value a, Value b) {
  switch (op) {
    case CompareOp::Lt: return a < b;
    case CompareOp::Le: return a <= b;
    case CompareOp::Gt: return a > b;
    case CompareOp::Ge: return a >= b;
    case CompareOp::Eq: return a == b;
    case CompareOp::Ne: return a != b;
  }
  return false;
}

// Runs plans for one round. New tuples are buffered per head predicate and
// only inserted after the round, so relations and indexes are never modified
// while they are being iterated.
class RoundRunner {
 public:
  RoundRunner(const std::vector<Relation>& relations, const std::vector<std::size_t>& limit,
              const std::vector<std::size_t>& delta_lo, std::vector<std::vector<Value>>& out)
      : rels_(relations), limit_(limit), delta_lo_(delta_lo), out_(out) {}

  void run(const RulePlan& plan) {
    plan_ = &plan;
    env_.assign(plan.num_slots, 0);
    for (const Filter& f : plan.pre_filters)
      if (!passes(f)) return;
    step(0);
  }

 private:
  Value value(const Source& s) const { return s.is_slot ? env_[s.slot] : s.constant; }

  bool passes(const Filter& f) {
    if (f.kind == Filter::Kind::Compare) return compare(f.op, value(f.lhs), value(f.rhs));
    Value buf[8];
    for (std::size_t i = 0; i < f.terms.size(); ++i) buf[i] = value(f.terms[i]);
    return !rels_[f.pred].contains(buf);
  }

  void emit() {
    const std::size_t n = plan_->head_terms.size();
    Value buf[8];
    for (std::size_t i = 0; i < n; ++i) buf[i] = value(plan_->head_terms[i]);
    // Skip tuples already known; duplicates within the round are removed on insert.
    if (rels_[plan_->head].contains(buf)) return;
    auto& v = out_[plan_->head];
    v.insert(v.end(), buf, buf + n);
  }

  // Applies a candidate tuple of step `i`; recurses on success.
  void accept(const JoinStep& s, std::size_t i, const Value* t) {
    for (const ColumnBind& b : s.binds) env_[b.slot] = t[b.column];
    for (const ColumnCheck& c : s.checks)
      if (t[c.column] != value(c.expected)) return;
    for (const Filter& f : s.filters)
      if (!passes(f)) return;
    step(i + 1);
  }

  void step(std::size_t i) {
    if (i == plan_->steps.size()) {
      emit();
      return;
    }
    const JoinStep& s = plan_->steps[i];
    const Relation& rel = rels_[s.pred];
    std::size_t lo = 0, hi = limit_[s.pred];
    if (s.range == StepRange::Old) hi = delta_lo_[s.pred];
    if (s.range == StepRange::Delta) lo = delta_lo_[s.pred];

    if (s.index) {
      Value key[8];
      for (std::size_t k = 0; k < s.key.size(); ++k) key[k] = value(s.key[k]);
      const auto& cols = s.index->columns();
      const std::uint64_t h = hash_values(key, s.key.size());
      for (TupleId id = s.index->head(h); id != kNoTuple; id = s.index->next(id)) {
        if (id >= hi) continue;
        if (id < lo) break;
        const Value* t = rel.tuple(id);
        bool match = true;
        for (std::size_t k = 0; k < cols.size(); ++k)
          if (t[cols[k]] != key[k]) { match = false; break; }
        if (match) accept(s, i, t);
      }
    } else {
      for (std::size_t id = lo; id < hi; ++id) accept(s, i, rel.tuple(static_cast<TupleId>(id)));
    }
  }

  const std::vector<Relation>& rels_;
  const std::vector<std::size_t>& limit_;
  const std::vector<std::size_t>& delta_lo_;
  std::vector<std::vector<Value>>& out_;
  const RulePlan* plan_ = nullptr;
  std::vector<Value> env_;
};

}  // namespace

void evaluate_component(const ComponentPlan& plan, std::vector<Relation>& relations) {
  const std::size_t np = relations.size();
  std::vector<std::size_t> limit(np), delta_lo(np);
  std::vector<std::vector<Value>> pending(np);

  auto snapshot = [&] {
    for (std::size_t p = 0; p < np; ++p) limit[p] = relations[p].size();
  };
  // Inserts the buffered tuples (deduplicating) and empties the buffers.
  auto flush = [&] {
    for (PredId p : plan.predicates) {
      auto& buf = pending[p];
      const std::size_t arity = relations[p].arity();
      for (std::size_t k = 0; k < buf.size(); k += arity) relations[p].insert(buf.data() + k);
      buf.clear();
    }
  };

  // Round 0: every rule once over the relations as they are.
  snapshot();
  for (PredId p : plan.predicates) delta_lo[p] = limit[p];
  {
    RoundRunner runner(relations, limit, delta_lo, pending);
    for (const RulePlan& r : plan.initial) runner.run(r);
  }
  flush();
  if (plan.delta.empty()) return;

  // Later rounds: delta = tuples added by the previous round.
  for (;;) {
    snapshot();
    bool any = false;
    for (PredId p : plan.predicates) any = any || limit[p] > delta_lo[p];
    if (!any) break;
    {
      RoundRunner runner(relations, limit, delta_lo, pending);
      for (const RulePlan& r : plan.delta) runner.run(r);
    }
    for (PredId p : plan.predicates) delta_lo[p] = limit[p];
    flush();
  }
}

}  // namespace datalog

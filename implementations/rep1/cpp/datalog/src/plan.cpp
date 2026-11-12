#include "datalog/plan.h"

#include <map>
#include <set>

namespace datalog {
namespace {

struct Compiler {
  const Rule& rule;
  PlanContext& ctx;
  std::map<std::string, std::uint32_t> slots;

  std::uint32_t slot_of(const std::string& name) {
    auto it = slots.find(name);
    if (it != slots.end()) return it->second;
    std::uint32_t s = static_cast<std::uint32_t>(slots.size());
    slots.emplace(name, s);
    return s;
  }

  Source source(const Term& t) {
    Source s;
    if (t.is_constant()) {
      s.constant = *ctx.encoder.encode(t.constant_value());
    } else {
      s.is_slot = true;
      s.slot = slot_of(t.variable_name());
    }
    return s;
  }

  static std::set<std::uint32_t> slots_of(const Filter& f) {
    std::set<std::uint32_t> r;
    auto add = [&](const Source& s) { if (s.is_slot) r.insert(s.slot); };
    add(f.lhs);
    add(f.rhs);
    for (const Source& s : f.terms) add(s);
    return r;
  }
};

}  // namespace

RulePlan compile_rule(const Rule& rule, int delta_literal, PlanContext& ctx) {
  Compiler c{rule, ctx, {}};
  RulePlan plan;
  plan.head = *ctx.preds.find(rule.head.predicate, rule.head.arity());

  // Slots for every named variable of the rule (safe rules bind them all).
  // Anonymous variables get no slot: they never need to be remembered.
  for (const Term& t : rule.head.args)
    if (t.is_variable()) c.slot_of(t.variable_name());
  for (const Literal& l : rule.body) {
    if (l.kind == Literal::Kind::Comparison) {
      if (l.lhs.is_variable()) c.slot_of(l.lhs.variable_name());
      if (l.rhs.is_variable()) c.slot_of(l.rhs.variable_name());
    } else {
      for (const Term& t : l.atom.args)
        if (t.is_variable()) c.slot_of(t.variable_name());
    }
  }
  plan.num_slots = c.slots.size();
  for (const Term& t : rule.head.args) plan.head_terms.push_back(c.source(t));

  // Filters (comparisons, negated atoms) waiting for their variables.
  std::vector<Filter> pending;
  for (const Literal& l : rule.body) {
    Filter f;
    if (l.kind == Literal::Kind::Comparison) {
      f.kind = Filter::Kind::Compare;
      f.op = l.op;
      f.lhs = c.source(l.lhs);
      f.rhs = c.source(l.rhs);
    } else if (l.kind == Literal::Kind::Negative) {
      f.kind = Filter::Kind::NotIn;
      f.pred = *ctx.preds.find(l.atom.predicate, l.atom.arity());
      for (const Term& t : l.atom.args) f.terms.push_back(c.source(t));
    } else {
      continue;
    }
    pending.push_back(std::move(f));
  }

  // Positive atoms, by body position.
  std::vector<std::size_t> remaining;
  for (std::size_t i = 0; i < rule.body.size(); ++i)
    if (rule.body[i].kind == Literal::Kind::Positive) remaining.push_back(i);

  std::set<std::uint32_t> bound;

  auto take_filters = [&](std::vector<Filter>& into) {
    for (auto it = pending.begin(); it != pending.end();) {
      bool ready = true;
      for (std::uint32_t s : Compiler::slots_of(*it))
        if (!bound.count(s)) { ready = false; break; }
      if (ready) {
        into.push_back(std::move(*it));
        it = pending.erase(it);
      } else {
        ++it;
      }
    }
  };
  take_filters(plan.pre_filters);

  auto bound_args = [&](const Atom& a) {
    int n = 0;
    for (const Term& t : a.args) {
      if (t.is_constant() || (t.is_variable() && bound.count(c.slots.at(t.variable_name())))) ++n;
    }
    return n;
  };

  bool first = true;
  while (!remaining.empty()) {
    std::size_t pick = 0;
    if (first && delta_literal >= 0) {
      for (std::size_t k = 0; k < remaining.size(); ++k)
        if (remaining[k] == static_cast<std::size_t>(delta_literal)) pick = k;
    } else {
      int best = -1;
      for (std::size_t k = 0; k < remaining.size(); ++k) {
        int b = bound_args(rule.body[remaining[k]].atom);
        if (b > best) { best = b; pick = k; }
      }
    }
    const std::size_t body_pos = remaining[pick];
    remaining.erase(remaining.begin() + pick);
    const Atom& atom = rule.body[body_pos].atom;

    JoinStep step;
    step.pred = *ctx.preds.find(atom.predicate, atom.arity());
    const bool is_delta = first && delta_literal >= 0;
    if (is_delta) {
      step.range = StepRange::Delta;
    } else if (delta_literal >= 0 && static_cast<int>(body_pos) < delta_literal &&
               ctx.in_component(step.pred)) {
      step.range = StepRange::Old;
    }

    // Classify columns.
    std::uint32_t mask = 0;
    std::vector<Source> key;
    std::set<std::uint32_t> bound_here;  // bound by an earlier column of this atom
    for (std::uint32_t col = 0; col < atom.arity(); ++col) {
      const Term& t = atom.args[col];
      if (t.is_anonymous()) continue;
      Source src = c.source(t);
      bool is_bound = !src.is_slot || bound.count(src.slot);
      if (is_bound) {
        if (is_delta) {
          step.checks.push_back({col, src});
        } else {
          mask |= 1u << col;
          key.push_back(src);
        }
      } else if (bound_here.count(src.slot)) {
        step.checks.push_back({col, src});
      } else {
        step.binds.push_back({col, src.slot});
        bound_here.insert(src.slot);
      }
    }
    if (mask != 0) {
      step.index = &ctx.relations[step.pred].index(mask);
      step.key = std::move(key);
    }
    for (std::uint32_t s : bound_here) bound.insert(s);
    take_filters(step.filters);
    plan.steps.push_back(std::move(step));
    first = false;
  }
  return plan;
}

}  // namespace datalog

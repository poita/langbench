#include "datalog/engine.h"

#include <algorithm>
#include <map>

#include "datalog/analysis.h"
#include "datalog/error.h"
#include "datalog/evaluator.h"
#include "datalog/plan.h"

namespace datalog {

Engine::Engine(const Program& program)
    : preds_(PredicateTable::of(program)), encoder_(ValueEncoder::of(program)) {
  if (auto why = find_unsafe_rule(program)) throw ProgramError(*why);
  auto strata = stratify(program, preds_);
  if (!strata) throw ProgramError("program is not stratifiable");

  relations_.reserve(preds_.size());
  for (PredId p = 0; p < preds_.size(); ++p) relations_.emplace_back(preds_.arity(p));

  // Facts go straight into their relations; rules are grouped by the
  // component of their head.
  std::vector<std::vector<const Rule*>> rules_of(strata->components.size());
  for (const Rule& r : program.rules) {
    PredId head = *preds_.find(r.head.predicate, r.head.arity());
    if (r.is_fact()) {
      Value buf[8];
      for (std::size_t i = 0; i < r.head.args.size(); ++i)
        buf[i] = *encoder_.encode(r.head.args[i].constant_value());
      relations_[head].insert(buf);
    } else {
      rules_of[strata->component_of[head]].push_back(&r);
    }
  }

  for (std::size_t c = 0; c < strata->components.size(); ++c) {
    if (rules_of[c].empty()) continue;
    PlanContext ctx{preds_, encoder_, relations_,
                    [&](PredId p) { return strata->component_of[p] == c; }};
    ComponentPlan plan;
    plan.predicates = strata->components[c];
    for (const Rule* r : rules_of[c]) {
      plan.initial.push_back(compile_rule(*r, -1, ctx));
      for (std::size_t i = 0; i < r->body.size(); ++i) {
        const Literal& l = r->body[i];
        if (l.kind != Literal::Kind::Positive) continue;
        PredId q = *preds_.find(l.atom.predicate, l.atom.arity());
        if (strata->component_of[q] == c)
          plan.delta.push_back(compile_rule(*r, static_cast<int>(i), ctx));
      }
    }
    evaluate_component(plan, relations_);
  }
}

std::size_t Engine::size(const std::string& name, std::size_t arity) const {
  auto id = preds_.find(name, arity);
  return id ? relations_[*id].size() : 0;
}

std::vector<Tuple> Engine::query(const Atom& q) const {
  std::vector<Tuple> result;
  auto id = preds_.find(q.predicate, q.arity());
  if (!id) return result;
  const Relation& rel = relations_[*id];
  const std::size_t n = q.arity();

  // Resolve the pattern: constants to values, variables to first-occurrence columns.
  std::vector<bool> is_const(n, false);
  std::vector<Value> want(n, 0);
  std::vector<int> same_as(n, -1);  // column of an earlier occurrence of the same variable
  std::map<std::string, int> first;
  for (std::size_t i = 0; i < n; ++i) {
    const Term& t = q.args[i];
    if (t.is_constant()) {
      auto v = encoder_.encode(t.constant_value());
      if (!v) return result;  // a symbol that occurs nowhere in the program
      is_const[i] = true;
      want[i] = *v;
    } else if (t.is_variable()) {
      auto it = first.emplace(t.variable_name(), static_cast<int>(i));
      if (!it.second) same_as[i] = it.first->second;
    }
  }

  std::vector<TupleId> matches;
  for (TupleId t = 0; t < rel.size(); ++t) {
    const Value* v = rel.tuple(t);
    bool ok = true;
    for (std::size_t i = 0; i < n && ok; ++i) {
      if (is_const[i]) ok = v[i] == want[i];
      else if (same_as[i] >= 0) ok = v[i] == v[same_as[i]];
    }
    if (ok) matches.push_back(t);
  }
  std::sort(matches.begin(), matches.end(), [&](TupleId a, TupleId b) {
    return std::lexicographical_compare(rel.tuple(a), rel.tuple(a) + n, rel.tuple(b),
                                        rel.tuple(b) + n);
  });
  result.reserve(matches.size());
  for (TupleId t : matches) {
    Tuple row;
    row.reserve(n);
    for (std::size_t i = 0; i < n; ++i) row.push_back(encoder_.decode(rel.tuple(t)[i]));
    result.push_back(std::move(row));
  }
  return result;
}

}  // namespace datalog

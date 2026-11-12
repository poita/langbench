#include "datalog/predicates.h"

namespace datalog {

PredId PredicateTable::intern(const std::string& name, std::size_t arity) {
  auto key = std::make_pair(name, arity);
  auto it = ids_.find(key);
  if (it != ids_.end()) return it->second;
  PredId id = static_cast<PredId>(keys_.size());
  ids_.emplace(key, id);
  keys_.push_back(std::move(key));
  return id;
}

std::optional<PredId> PredicateTable::find(const std::string& name, std::size_t arity) const {
  auto it = ids_.find(std::make_pair(name, arity));
  if (it == ids_.end()) return std::nullopt;
  return it->second;
}

PredicateTable PredicateTable::of(const Program& program) {
  PredicateTable t;
  for (const Rule& r : program.rules) {
    t.intern(r.head.predicate, r.head.arity());
    for (const Literal& l : r.body) {
      if (l.kind != Literal::Kind::Comparison) t.intern(l.atom.predicate, l.atom.arity());
    }
  }
  for (const Atom& q : program.queries) t.intern(q.predicate, q.arity());
  return t;
}

}  // namespace datalog

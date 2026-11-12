#include "datalog/analysis.h"

#include <algorithm>
#include <set>

namespace datalog {
namespace {

std::string describe_rule(const Rule& r) {
  std::string s = to_string(r.head);
  return r.is_fact() ? s + "." : s + " :- ...";
}

// Tarjan's SCC algorithm. Edges go from a predicate to the predicates it
// depends on, so components are emitted dependencies-first.
struct Tarjan {
  const std::vector<std::vector<PredId>>& adj;
  std::vector<int> index, low;
  std::vector<bool> on_stack;
  std::vector<PredId> stack;
  std::vector<std::vector<PredId>> components;
  std::vector<std::size_t> component_of;
  int counter = 0;

  explicit Tarjan(const std::vector<std::vector<PredId>>& a)
      : adj(a), index(a.size(), -1), low(a.size(), 0), on_stack(a.size(), false),
        component_of(a.size(), 0) {}

  void run() {
    for (PredId v = 0; v < adj.size(); ++v)
      if (index[v] < 0) visit(v);
  }

  void visit(PredId v) {
    index[v] = low[v] = counter++;
    stack.push_back(v);
    on_stack[v] = true;
    for (PredId w : adj[v]) {
      if (index[w] < 0) {
        visit(w);
        low[v] = std::min(low[v], low[w]);
      } else if (on_stack[w]) {
        low[v] = std::min(low[v], index[w]);
      }
    }
    if (low[v] == index[v]) {
      std::vector<PredId> comp;
      PredId w;
      do {
        w = stack.back();
        stack.pop_back();
        on_stack[w] = false;
        component_of[w] = components.size();
        comp.push_back(w);
      } while (w != v);
      std::sort(comp.begin(), comp.end());
      components.push_back(std::move(comp));
    }
  }
};

}  // namespace

std::optional<std::string> find_unsafe_rule(const Program& program) {
  for (const Rule& rule : program.rules) {
    std::set<std::string> bound;
    for (const Literal& l : rule.body) {
      if (l.kind != Literal::Kind::Positive) continue;
      for (const Term& t : l.atom.args)
        if (t.is_variable()) bound.insert(t.variable_name());
    }
    auto check = [&](const Term& t) -> bool {
      if (t.is_anonymous()) return false;
      if (t.is_variable()) return bound.count(t.variable_name()) > 0;
      return true;
    };
    bool ok = true;
    for (const Term& t : rule.head.args) ok = ok && check(t);
    for (const Literal& l : rule.body) {
      if (l.kind == Literal::Kind::Negative) {
        for (const Term& t : l.atom.args) ok = ok && check(t);
      } else if (l.kind == Literal::Kind::Comparison) {
        ok = ok && check(l.lhs) && check(l.rhs);
      }
    }
    if (!ok) return "unsafe rule: " + describe_rule(rule);
  }
  return std::nullopt;
}

std::optional<Stratification> stratify(const Program& program, const PredicateTable& preds) {
  const std::size_t n = preds.size();
  std::vector<std::vector<PredId>> adj(n);
  struct Edge { PredId from, to; };
  std::vector<Edge> negative;
  for (const Rule& r : program.rules) {
    PredId head = *preds.find(r.head.predicate, r.head.arity());
    for (const Literal& l : r.body) {
      if (l.kind == Literal::Kind::Comparison) continue;
      PredId q = *preds.find(l.atom.predicate, l.atom.arity());
      adj[head].push_back(q);
      if (l.kind == Literal::Kind::Negative) negative.push_back({head, q});
    }
  }
  for (auto& a : adj) {
    std::sort(a.begin(), a.end());
    a.erase(std::unique(a.begin(), a.end()), a.end());
  }
  Tarjan t(adj);
  t.run();
  for (const Edge& e : negative)
    if (t.component_of[e.from] == t.component_of[e.to]) return std::nullopt;
  Stratification s;
  s.components = std::move(t.components);
  s.component_of = std::move(t.component_of);
  return s;
}

}  // namespace datalog

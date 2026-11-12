#include "datalog/analysis.h"

#include <algorithm>
#include <map>
#include <set>

namespace datalog {

PredicateKey key_of(const Atom& atom) {
  return PredicateKey{atom.predicate, atom.args.size()};
}

bool is_safe(const Rule& rule) {
  std::set<std::string> bound;
  for (const Literal& lit : rule.body) {
    if (lit.kind != Literal::Kind::Positive) continue;
    for (const Term& t : lit.atom.args)
      if (t.kind == Term::Kind::Variable) bound.insert(t.variable);
  }
  auto ok = [&](const Term& t) {
    if (t.kind == Term::Kind::Anonymous) return false;
    if (t.kind == Term::Kind::Variable) return bound.count(t.variable) > 0;
    return true;
  };
  for (const Term& t : rule.head.args)
    if (!ok(t)) return false;
  for (const Literal& lit : rule.body) {
    if (lit.kind == Literal::Kind::Negative) {
      for (const Term& t : lit.atom.args)
        if (!ok(t)) return false;
    } else if (lit.kind == Literal::Kind::Comparison) {
      if (!ok(lit.lhs) || !ok(lit.rhs)) return false;
    }
  }
  return true;
}

void check_safety(const Program& program) {
  for (const Rule& r : program.rules)
    if (!is_safe(r)) throw ProgramError("unsafe rule for " + r.head.predicate);
}

namespace {

struct Graph {
  struct Edge {
    int to;
    bool negative;
  };
  std::vector<std::vector<Edge>> adj;  // head -> body predicate
};

// Tarjan's algorithm. Components are emitted with all their dependencies
// already emitted, which is exactly evaluation order.
class Tarjan {
 public:
  explicit Tarjan(const Graph& g)
      : g_(g), index_(g.adj.size(), -1), low_(g.adj.size(), 0),
        on_stack_(g.adj.size(), false), comp_(g.adj.size(), -1) {}

  void run() {
    for (std::size_t v = 0; v < g_.adj.size(); ++v)
      if (index_[v] < 0) visit(static_cast<int>(v));
  }
  const std::vector<std::vector<int>>& components() const { return comps_; }
  const std::vector<int>& component_of() const { return comp_; }

 private:
  void visit(int root) {
    // Iterative DFS to be safe on deep dependency chains.
    struct Frame { int v; std::size_t edge; };
    std::vector<Frame> call{{root, 0}};
    open(root);
    while (!call.empty()) {
      Frame& f = call.back();
      if (f.edge < g_.adj[f.v].size()) {
        int w = g_.adj[f.v][f.edge++].to;
        if (index_[w] < 0) {
          open(w);
          call.push_back({w, 0});
        } else if (on_stack_[w]) {
          low_[f.v] = std::min(low_[f.v], index_[w]);
        }
      } else {
        int v = f.v;
        if (low_[v] == index_[v]) {
          std::vector<int> comp;
          int w;
          do {
            w = stack_.back();
            stack_.pop_back();
            on_stack_[w] = false;
            comp_[w] = static_cast<int>(comps_.size());
            comp.push_back(w);
          } while (w != v);
          comps_.push_back(std::move(comp));
        }
        call.pop_back();
        if (!call.empty())
          low_[call.back().v] = std::min(low_[call.back().v], low_[v]);
      }
    }
  }
  void open(int v) {
    index_[v] = low_[v] = counter_++;
    stack_.push_back(v);
    on_stack_[v] = true;
  }

  const Graph& g_;
  std::vector<int> index_, low_;
  std::vector<bool> on_stack_;
  std::vector<int> comp_;
  std::vector<int> stack_;
  std::vector<std::vector<int>> comps_;
  int counter_ = 0;
};

}  // namespace

std::vector<std::vector<PredicateKey>> stratify(const Program& program) {
  std::map<PredicateKey, int> ids;
  std::vector<PredicateKey> keys;
  auto id_of = [&](const Atom& a) {
    PredicateKey k = key_of(a);
    auto [it, inserted] = ids.emplace(k, static_cast<int>(keys.size()));
    if (inserted) keys.push_back(std::move(k));
    return it->second;
  };

  struct RawEdge { int from, to; bool negative; };
  std::vector<RawEdge> raw;
  for (const Rule& r : program.rules) {
    int head = id_of(r.head);
    for (const Literal& lit : r.body) {
      if (lit.kind == Literal::Kind::Comparison) continue;
      raw.push_back({head, id_of(lit.atom),
                     lit.kind == Literal::Kind::Negative});
    }
  }
  Graph g;
  g.adj.resize(keys.size());
  for (const RawEdge& e : raw) g.adj[e.from].push_back({e.to, e.negative});

  Tarjan t(g);
  t.run();
  for (const RawEdge& e : raw)
    if (e.negative && t.component_of()[e.from] == t.component_of()[e.to])
      throw ProgramError("program is not stratifiable: negation on a cycle (" +
                         keys[e.from].name + ")");

  std::vector<std::vector<PredicateKey>> out;
  for (const auto& comp : t.components()) {
    std::vector<PredicateKey> c;
    for (int v : comp) c.push_back(keys[v]);
    std::sort(c.begin(), c.end());
    out.push_back(std::move(c));
  }
  return out;
}

}  // namespace datalog

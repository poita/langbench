#include "kiln/graph.hpp"

#include <unordered_set>

#include "kiln/error.hpp"

namespace kiln {

int Graph::resolve(const std::string& ref) {
  if (!ref.empty() && ref[0] == '@') {
    auto it = phonyNodes_.find(ref.substr(1));
    return it == phonyNodes_.end() ? -1 : it->second;
  }
  auto o = outputOwner_.find(ref);
  if (o != outputOwner_.end()) return o->second;
  auto s = sourceNodes_.find(ref);
  if (s != sourceNodes_.end()) return s->second;
  if (!vfs_->exists(ref)) return -1;
  int id = static_cast<int>(nodes_.size());
  Node n;
  n.kind = Node::SourceNode;
  n.name = ref;
  nodes_.push_back(std::move(n));
  sourceNodes_.emplace(ref, id);
  return id;
}

namespace {
void appendUnique(std::vector<int>& out, const std::vector<int>& deps) {
  std::unordered_set<int> seen;
  for (int d : deps)
    if (seen.insert(d).second) out.push_back(d);
}
}  // namespace

Graph Graph::build(const BuildPlan& plan, const Vfs& vfs) {
  Graph g;
  g.vfs_ = &vfs;
  const int S = static_cast<int>(plan.steps.size());
  for (const auto& st : plan.steps) {
    Node n;
    n.kind = Node::StepNode;
    n.ref = st.serial;
    n.name = st.primary();
    g.nodes_.push_back(std::move(n));
  }
  for (std::size_t i = 0; i < plan.phonies.size(); ++i) {
    Node n;
    n.kind = Node::PhonyNode;
    n.ref = static_cast<int>(i);
    n.name = "@" + plan.phonies[i].name;
    g.phonyNodes_.emplace(plan.phonies[i].name, S + static_cast<int>(i));
    g.nodes_.push_back(std::move(n));
  }

  // 1. Duplicate outputs.
  for (int i = 0; i < S; ++i) {
    for (const auto& path : plan.steps[static_cast<std::size_t>(i)].fullOutputs()) {
      if (!g.outputOwner_.emplace(path, i).second) throw Error("E_DUP_OUTPUT", path);
    }
  }

  // 2. Reference resolution.
  for (int i = 0; i < S; ++i) {
    const Step& st = plan.steps[static_cast<std::size_t>(i)];
    std::vector<int> deps;
    for (const auto* list : {&st.inputs, &st.after}) {
      for (const auto& ref : *list) {
        int id = g.resolve(ref);
        if (id < 0) throw Error("E_MISSING_INPUT", ref + " required by " + st.primary());
        deps.push_back(id);
      }
    }
    appendUnique(g.nodes_[static_cast<std::size_t>(i)].succ, deps);
  }
  for (std::size_t p = 0; p < plan.phonies.size(); ++p) {
    std::vector<int> deps;
    for (const auto& ref : plan.phonies[p].deps) {
      int id = g.resolve(ref);
      if (id < 0) throw Error("E_MISSING_INPUT", ref + " required by @" + plan.phonies[p].name);
      deps.push_back(id);
    }
    appendUnique(g.nodes_[static_cast<std::size_t>(S) + p].succ, deps);
  }

  // 3. Default list.
  for (const auto& ref : plan.defaults)
    if (g.resolve(ref) < 0) throw Error("E_UNKNOWN_TARGET", ref);
  return g;
}

std::vector<int> Graph::requestedRoots(const BuildPlan& plan,
                                       const std::vector<std::string>& targets) {
  const std::vector<std::string>& source = targets.empty() ? plan.defaults : targets;
  std::vector<std::string> names;
  std::unordered_set<std::string> seen;
  for (const auto& t : source)
    if (seen.insert(t).second) names.push_back(t);
  if (names.empty()) throw Error("E_NO_DEFAULT");
  std::vector<int> roots;
  for (const auto& t : names) {
    int id = resolve(t);
    if (id < 0) throw Error("E_UNKNOWN_TARGET", t);
    roots.push_back(id);
  }
  return roots;
}

std::vector<char> Graph::reachableFrom(const std::vector<int>& roots) const {
  enum : char { White = 0, Grey = 1, Black = 2 };
  std::vector<char> colour(nodes_.size(), White);
  struct Frame {
    int node;
    std::size_t next;
  };
  std::vector<Frame> stack;
  for (int root : roots) {
    if (colour[static_cast<std::size_t>(root)] != White) continue;
    colour[static_cast<std::size_t>(root)] = Grey;
    stack.push_back({root, 0});
    while (!stack.empty()) {
      Frame& top = stack.back();
      const auto& succ = nodes_[static_cast<std::size_t>(top.node)].succ;
      if (top.next < succ.size()) {
        int m = succ[top.next++];
        char c = colour[static_cast<std::size_t>(m)];
        if (c == Grey) {
          std::size_t j = 0;
          while (stack[j].node != m) ++j;
          std::string msg;
          for (std::size_t k = j; k < stack.size(); ++k) {
            msg += nodes_[static_cast<std::size_t>(stack[k].node)].name;
            msg += " -> ";
          }
          msg += nodes_[static_cast<std::size_t>(m)].name;
          throw Error("E_CYCLE", msg);
        }
        if (c == White) {
          colour[static_cast<std::size_t>(m)] = Grey;
          stack.push_back({m, 0});
        }
      } else {
        colour[static_cast<std::size_t>(top.node)] = Black;
        stack.pop_back();
      }
    }
  }
  std::vector<char> reach(nodes_.size(), 0);
  for (std::size_t i = 0; i < colour.size(); ++i) reach[i] = colour[i] != White;
  return reach;
}

}  // namespace kiln

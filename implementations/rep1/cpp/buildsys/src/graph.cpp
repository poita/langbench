#include "kiln/graph.hpp"

#include <unordered_set>

#include "kiln/error.hpp"

namespace kiln {

namespace {
void push_unique(std::vector<std::size_t>& v, std::size_t id) {
  for (std::size_t x : v) {
    if (x == id) return;
  }
  v.push_back(id);
}
}  // namespace

Graph::Graph(const BuildDescription& desc, const Vfs& vfs) : desc_(desc), vfs_(vfs) {
  const std::size_t S = desc.steps.size();
  for (std::size_t i = 0; i < S; ++i) {
    nodes_.push_back(Node{NodeKind::Step, i, desc.steps[i].primary(), {}});
  }
  for (std::size_t i = 0; i < desc.phonies.size(); ++i) {
    nodes_.push_back(Node{NodeKind::Phony, i, "@" + desc.phonies[i].name, {}});
    by_phony_.emplace(desc.phonies[i].name, S + i);
  }

  // 1. Duplicate outputs (declared outputs, then the depfile).
  for (std::size_t i = 0; i < S; ++i) {
    for (const auto& p : desc.steps[i].full_outputs()) {
      if (!by_output_.emplace(p, i).second) throw Error(ErrorKind::DupOutput, p);
    }
  }

  // 2. Reference resolution for steps, then phony targets.
  auto resolve_dep = [&](const std::string& ref, const std::string& owner) {
    auto id = resolve(ref);
    if (!id) throw Error(ErrorKind::MissingInput, ref + " required by " + owner);
    return *id;
  };
  for (std::size_t i = 0; i < S; ++i) {
    const StepDef& st = desc.steps[i];
    std::vector<std::size_t> succ;
    for (const auto& in : st.inputs) succ.push_back(resolve_dep(in, nodes_[i].name));
    for (const auto& a : st.after) succ.push_back(resolve_dep(a, nodes_[i].name));
    for (std::size_t id : succ) push_unique(nodes_[i].succ, id);
  }
  for (std::size_t i = 0; i < desc.phonies.size(); ++i) {
    const std::size_t id = S + i;
    std::vector<std::size_t> succ;
    for (const auto& d : desc.phonies[i].deps) succ.push_back(resolve_dep(d, nodes_[id].name));
    for (std::size_t s : succ) push_unique(nodes_[id].succ, s);
  }

  // 3. Default list.
  for (const auto& t : desc.defaults) {
    if (!resolve(t)) throw Error(ErrorKind::UnknownTarget, t);
  }
}

std::size_t Graph::add_source(const std::string& path) {
  auto it = by_source_.find(path);
  if (it != by_source_.end()) return it->second;
  std::size_t id = nodes_.size();
  nodes_.push_back(Node{NodeKind::Source, 0, path, {}});
  by_source_.emplace(path, id);
  return id;
}

std::optional<std::size_t> Graph::resolve(std::string_view ref) {
  if (!ref.empty() && ref[0] == '@') {
    auto it = by_phony_.find(std::string(ref.substr(1)));
    if (it == by_phony_.end()) return std::nullopt;
    return it->second;
  }
  std::string key(ref);
  auto out = by_output_.find(key);
  if (out != by_output_.end()) return out->second;
  if (vfs_.exists(ref)) return add_source(key);
  return std::nullopt;
}

std::vector<bool> Graph::plan(const std::vector<std::string>& explicit_targets) {
  std::vector<std::string> wanted;
  const std::vector<std::string>& src = explicit_targets.empty() ? desc_.defaults : explicit_targets;
  {
    std::unordered_set<std::string> seen;
    for (const auto& t : src) {
      if (seen.insert(t).second) wanted.push_back(t);
    }
  }
  if (wanted.empty()) throw Error(ErrorKind::NoDefault);
  std::vector<std::size_t> roots;
  for (const auto& t : wanted) {
    auto id = resolve(t);
    if (!id) throw Error(ErrorKind::UnknownTarget, t);
    roots.push_back(*id);
  }

  enum Colour : char { White, Grey, Black };
  std::vector<char> colour(nodes_.size(), White);
  struct Frame {
    std::size_t node;
    std::size_t next;
  };
  for (std::size_t root : roots) {
    if (colour[root] != White) continue;
    colour[root] = Grey;
    std::vector<Frame> stack{{root, 0}};
    while (!stack.empty()) {
      Frame& top = stack.back();
      const auto& succ = nodes_[top.node].succ;
      if (top.next < succ.size()) {
        std::size_t m = succ[top.next++];
        if (colour[m] == Grey) {
          std::size_t j = 0;
          while (stack[j].node != m) ++j;
          std::string text;
          for (std::size_t k = j; k < stack.size(); ++k) text += nodes_[stack[k].node].name + " -> ";
          text += nodes_[m].name;
          throw Error(ErrorKind::Cycle, text);
        }
        if (colour[m] == White) {
          colour[m] = Grey;
          stack.push_back({m, 0});
        }
      } else {
        colour[top.node] = Black;
        stack.pop_back();
      }
    }
  }
  std::vector<bool> reachable(nodes_.size());
  for (std::size_t i = 0; i < nodes_.size(); ++i) reachable[i] = colour[i] != White;
  return reachable;
}

}  // namespace kiln

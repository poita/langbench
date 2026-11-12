// The dependency graph over steps, phony targets and source files.
#pragma once

#include <string>
#include <unordered_map>
#include <vector>

#include "kiln/plan.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

struct Node {
  enum Kind { StepNode, PhonyNode, SourceNode };
  Kind kind = StepNode;
  int ref = 0;                 // step serial / phony index (unused for sources)
  std::string name;            // primary output, "@phony", or source path
  std::vector<int> succ;       // ordering dependencies, deduplicated
};

/// Node ids: steps occupy `0 .. S-1` (id == serial), phony targets follow, and
/// source nodes are appended on demand.
class Graph {
 public:
  /// Builds the graph and performs SPEC's whole-graph validation: duplicate
  /// outputs, reference resolution, default list. Throws `Error`.
  static Graph build(const BuildPlan& plan, const Vfs& vfs);

  const Node& node(int id) const { return nodes_[static_cast<std::size_t>(id)]; }
  std::size_t size() const noexcept { return nodes_.size(); }

  /// Resolves a target reference; -1 if it names nothing. May create a source node.
  int resolve(const std::string& ref);

  /// Resolves the requested targets of a build (the `targets`, or the plan's
  /// defaults when empty). Throws `E_NO_DEFAULT` / `E_UNKNOWN_TARGET`.
  std::vector<int> requestedRoots(const BuildPlan& plan, const std::vector<std::string>& targets);

  /// Cycle detection by SPEC's depth-first search; returns, per node, whether
  /// it is reachable from `roots`. Throws `E_CYCLE`.
  std::vector<char> reachableFrom(const std::vector<int>& roots) const;

 private:
  const Vfs* vfs_ = nullptr;
  std::vector<Node> nodes_;
  std::unordered_map<std::string, int> outputOwner_;
  std::unordered_map<std::string, int> phonyNodes_;
  std::unordered_map<std::string, int> sourceNodes_;
};

}  // namespace kiln

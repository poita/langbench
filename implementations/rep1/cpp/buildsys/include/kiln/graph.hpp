// The dependency graph: validation, target resolution, cycle detection.
#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "kiln/step.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

enum class NodeKind { Step, Phony, Source };

struct Node {
  NodeKind kind;
  std::size_t index;               ///< step or phony index; unused for sources
  std::string name;                ///< primary output, `@phony`, or source path
  std::vector<std::size_t> succ;   ///< ordering dependencies, deduplicated, in order
};

/// The graph of one build. Node ids: steps first (id == serial), then phony
/// targets, then source nodes created on demand.
class Graph {
 public:
  /// Whole-graph validation: duplicate outputs, reference resolution, default
  /// list. Throws `E_DUP_OUTPUT`, `E_MISSING_INPUT` or `E_UNKNOWN_TARGET`.
  Graph(const BuildDescription& desc, const Vfs& vfs);

  /// Resolves a target reference (`@phony`, step output, existing file).
  std::optional<std::size_t> resolve(std::string_view ref);

  const Node& node(std::size_t id) const { return nodes_[id]; }
  std::size_t node_count() const { return nodes_.size(); }

  /// Picks the requested targets (`explicit_targets`, else the default list),
  /// throws `E_NO_DEFAULT` / `E_UNKNOWN_TARGET`, searches for cycles with the
  /// specified depth-first search (`E_CYCLE`), and returns the reachable set
  /// as a membership vector indexed by node id.
  std::vector<bool> plan(const std::vector<std::string>& explicit_targets);

 private:
  std::size_t add_source(const std::string& path);

  const BuildDescription& desc_;
  const Vfs& vfs_;
  std::vector<Node> nodes_;
  std::unordered_map<std::string, std::size_t> by_output_;
  std::unordered_map<std::string, std::size_t> by_phony_;
  std::unordered_map<std::string, std::size_t> by_source_;
};

}  // namespace kiln

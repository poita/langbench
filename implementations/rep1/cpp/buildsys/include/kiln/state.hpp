// The `.kiln-state` file: parsing, writing and change detection.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "kiln/step.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

using PathHash = std::pair<std::string, std::uint64_t>;

/// What was recorded about one successfully executed step.
struct StateEntry {
  std::string command;            ///< canonical command string
  std::vector<PathHash> inputs;   ///< declared file inputs, in order
  std::vector<PathHash> deps;     ///< discovered dependencies, ascending
  std::vector<PathHash> outputs;  ///< full output list, in order
};

/// The in-memory form of `.kiln-state`, keyed by primary output path.
class BuildState {
 public:
  /// Strictly parses a state file. Any deviation from the grammar yields an
  /// empty state.
  static BuildState parse(std::string_view text);

  /// Reads `.kiln-state` from the workspace (empty when absent or corrupt).
  static BuildState load(const Vfs& vfs);

  /// Canonical text: entries sorted by key, every line newline-terminated.
  std::string serialize() const;

  const StateEntry* find(const std::string& key) const;
  void put(const std::string& key, StateEntry entry);
  void erase(const std::string& key);
  std::size_t size() const { return entries_.size(); }

 private:
  std::map<std::string, StateEntry> entries_;
};

/// Change detection: whether `step` can be skipped given the recorded state and
/// the workspace as it stands now.
bool is_fresh(const StepDef& step, const BuildState& state, const Vfs& vfs);

}  // namespace kiln

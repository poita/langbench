// The `.kiln-state` file and change detection.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "kiln/plan.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

using PathHash = std::pair<std::string, std::uint64_t>;

/// What Kiln remembers about one executed step.
struct StateEntry {
  std::string cmd;
  std::vector<PathHash> ins;
  std::vector<PathHash> deps;
  std::vector<PathHash> outs;
};

/// The persisted build state, keyed by primary output path.
class BuildState {
 public:
  /// Reads `.kiln-state`; any deviation from the format yields an empty state.
  static BuildState load(const Vfs& vfs);

  /// Parses state text; returns an empty state if it is malformed.
  static BuildState parse(const std::string& text);

  /// Canonical serialisation (entries sorted by key).
  std::string serialize() const;

  /// Writes `.kiln-state` into the workspace.
  void save(Vfs& vfs) const;

  const StateEntry* find(const std::string& key) const;
  void replace(const std::string& key, StateEntry entry);
  void erase(const std::string& key);
  std::size_t size() const noexcept { return entries_.size(); }

 private:
  std::map<std::string, StateEntry> entries_;
};

/// SPEC "Change detection": true if `step` is up to date.
bool isFresh(const Step& step, const BuildState& state, const Vfs& vfs);

}  // namespace kiln

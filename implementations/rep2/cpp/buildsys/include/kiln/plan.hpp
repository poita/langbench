// The result of evaluating the build files: steps, phony targets, defaults.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "kiln/value.hpp"

namespace kiln {

struct CommandInfo;

/// A command invocation: its name and evaluated arguments (`str` or `int`).
struct CommandCall {
  std::string name;
  std::vector<Value> args;
};

/// One build step, as created by a `step` block.
struct Step {
  int serial = 0;
  std::vector<std::string> outputs;        // declared outputs; the first is primary
  std::optional<std::string> depfile;
  std::vector<std::string> inputs;         // declared `in` entries (may include @phony)
  std::vector<std::string> after;          // declared `after` entries
  CommandCall call;
  const CommandInfo* info = nullptr;
  std::int64_t cost = 0;
  std::string canonical;                   // canonical command string

  const std::string& primary() const { return outputs.front(); }

  /// Declared outputs followed by the depfile.
  std::vector<std::string> fullOutputs() const {
    std::vector<std::string> v = outputs;
    if (depfile) v.push_back(*depfile);
    return v;
  }

  /// Declared inputs that are not phony references, in order.
  std::vector<std::string> fileInputs() const {
    std::vector<std::string> v;
    for (const auto& i : inputs)
      if (i.empty() || i[0] != '@') v.push_back(i);
    return v;
  }
};

struct PhonyDecl {
  std::string name;  // without '@'
  std::vector<std::string> deps;
};

/// Everything a build's evaluation phase produces.
struct BuildPlan {
  std::vector<Step> steps;
  std::vector<PhonyDecl> phonies;
  std::vector<std::string> defaults;
};

}  // namespace kiln

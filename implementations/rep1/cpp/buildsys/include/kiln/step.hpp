// The product of evaluating build files: steps, phony targets, default targets.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "kiln/commands.hpp"
#include "kiln/value.hpp"

namespace kiln {

/// One build step, as created by a `step` block.
struct StepDef {
  std::size_t serial = 0;
  std::vector<std::string> outputs;   ///< declared outputs, in order
  std::vector<std::string> inputs;    ///< declared inputs (files and `@phony` references)
  std::vector<std::string> after;     ///< order-only dependencies
  std::string depfile;                ///< empty when absent
  std::int64_t cost = 0;              ///< effective cost (explicit or the command's default)
  const CommandSpec* command = nullptr;
  std::vector<Value> args;

  const std::string& primary() const { return outputs.front(); }

  /// Declared outputs followed by the depfile, if any.
  std::vector<std::string> full_outputs() const;

  /// Declared inputs that are not phony references, in order.
  std::vector<std::string> file_inputs() const;

  std::string canonical() const { return canonical_command(*command, args); }
};

struct PhonyDef {
  std::string name;                   ///< without the leading `@`
  std::vector<std::string> deps;
};

/// What evaluating `main.kiln` (and its includes) produced.
struct BuildDescription {
  std::vector<StepDef> steps;
  std::vector<PhonyDef> phonies;
  std::vector<std::string> defaults;
};

}  // namespace kiln

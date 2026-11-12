// The sixteen built-in commands.
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "kiln/plan.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

enum class ArgType { Str, Int };

/// Static description of a command (SPEC "The command set").
struct CommandInfo {
  const char* name;
  int minInputs;
  int maxInputs;  // -1: unbounded
  bool usesDepfile;
  std::int64_t defaultCost;
  std::vector<ArgType> args;
};

/// Looks up a command by name; nullptr if unknown.
const CommandInfo* findCommand(std::string_view name);

/// `name(arg, arg, ...)` with the SPEC's string escaping.
std::string canonicalCommand(const CommandCall& call);

/// What a command produces when it succeeds.
struct CommandResult {
  std::string output;                     // content of the primary output
  std::optional<std::string> depfile;     // content of the depfile, if any
  std::vector<std::string> discovered;    // discovered dependencies, sorted
};

/// Runs `step`'s command. `inputs` are the contents of the step's file inputs
/// in declared order; `vfs` is used by `preprocess` to read `@need` files.
/// Throws `Error` for execution errors (`E_NEED_*`).
CommandResult runCommand(const Step& step, const std::vector<Content>& inputs, const Vfs& vfs);

/// Splits content into lines per SPEC "Lines of a file".
std::vector<std::string_view> splitLines(std::string_view content);

}  // namespace kiln

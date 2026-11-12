// The sixteen built-in commands.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "kiln/value.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

enum class ArgType { Str, Int };

/// Static description of a command: signature, shape constraints, default cost.
struct CommandSpec {
  std::string_view name;
  std::vector<ArgType> args;
  int min_inputs;
  int max_inputs;  ///< -1 for "no upper bound"
  bool depfile_required;
  std::int64_t default_cost;
};

/// The spec for `name`, or null when it is not one of the sixteen commands.
const CommandSpec* find_command(std::string_view name);

/// `name(arg, arg, ...)` with the specification's string escaping.
std::string canonical_command(const CommandSpec& spec, const std::vector<Value>& args);

/// Command-specific argument checks (`E_ARG cmd ...`).
void check_command_args(const CommandSpec& spec, const std::vector<Value>& args);

/// A file input as read at the command's start time.
struct CommandInput {
  std::string path;
  Vfs::Content content;
};

struct CommandResult {
  std::string output;                 ///< content of the primary output
  std::string depfile;                ///< content of the depfile (preprocess only)
  std::vector<std::string> discovered;///< sorted discovered dependency paths
};

/// Runs a command against its inputs. `preprocess` also reads `fs` for `@need`
/// files and may throw `E_NEED_*`; no other command throws.
CommandResult run_command(const CommandSpec& spec, const std::vector<Value>& args,
                          const std::vector<CommandInput>& inputs, const Vfs& fs);

/// The lines of `content` per the specification (a trailing newline does not
/// start another line; empty content has no lines).
std::vector<std::string_view> split_lines(std::string_view content);

}  // namespace kiln

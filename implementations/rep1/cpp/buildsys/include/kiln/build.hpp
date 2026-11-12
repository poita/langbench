// One complete `build`: evaluate, validate, plan, execute, persist state.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "kiln/error.hpp"
#include "kiln/scheduler.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

struct BuildOptions {
  /// Targets as written on the build line (`@phony` or paths); empty means
  /// "use the default list".
  std::vector<std::string> targets;
  /// Simulated worker count (>= 1).
  int workers = 1;
};

struct BuildReport {
  std::optional<Error> error;          ///< set when the build failed
  std::vector<BuildEvent> events;      ///< empty for configuration errors
  std::size_t ran = 0;
  std::size_t hits = 0;
  std::int64_t time = 0;

  bool ok() const { return !error.has_value(); }
};

/// Runs a build against `vfs`. Configuration errors leave the workspace
/// untouched; once execution starts `.kiln-state` is always rewritten.
BuildReport run_build(Vfs& vfs, const BuildOptions& options);

}  // namespace kiln

// A complete build: evaluation, validation, scheduling and state handling.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "kiln/error.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

/// One line of build activity.
struct Event {
  enum Kind { Hit, Run, Fail, Cancel };
  Kind kind = Hit;
  int serial = 0;
  std::int64_t start = 0;  // for a hit: the time of the hit
  std::int64_t end = 0;
  int worker = 0;
  std::string target;      // primary output
  std::string command;     // canonical command string
};

/// The outcome of one build.
struct BuildReport {
  /// True once the build reached its execution phase (so `.kiln-state` was written).
  bool executed = false;
  std::vector<Event> events;       // sorted by (start, serial)
  std::optional<Error> error;
  int ran = 0;
  int hits = 0;
  std::int64_t time = 0;
};

/// Runs a build against `vfs`, mutating it exactly as SPEC "The build
/// algorithm" prescribes. `targets` empty means the default targets.
BuildReport runBuild(Vfs& vfs, const std::vector<std::string>& targets, int jobs);

}  // namespace kiln

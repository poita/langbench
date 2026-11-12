// Deterministic simulation of a parallel build.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "kiln/error.hpp"
#include "kiln/graph.hpp"
#include "kiln/state.hpp"
#include "kiln/step.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

/// One line of a build's event log.
struct BuildEvent {
  enum class Kind { Hit, Run, Fail, Cancel };
  Kind kind = Kind::Run;
  std::int64_t start = 0;   ///< for a hit, the time of the hit
  std::int64_t end = 0;
  int worker = 0;
  std::size_t serial = 0;
  std::string target;       ///< primary output of the step
  std::string command;      ///< canonical command string
};

struct ScheduleResult {
  std::vector<BuildEvent> events;   ///< sorted by (start, serial)
  std::size_t ran = 0;
  std::size_t hits = 0;
  std::int64_t time = 0;            ///< completion time
  std::optional<Error> error;       ///< execution error, if the build failed
};

/// Runs the reachable steps on `workers` simulated workers. Executed commands
/// write their outputs into `vfs` and update `state`; fresh steps are hits.
ScheduleResult run_schedule(const BuildDescription& desc, const Graph& graph,
                            const std::vector<bool>& reachable, Vfs& vfs, BuildState& state,
                            int workers);

}  // namespace kiln

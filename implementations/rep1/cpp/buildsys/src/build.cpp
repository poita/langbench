#include "kiln/build.hpp"

#include "kiln/evaluator.hpp"
#include "kiln/graph.hpp"
#include "kiln/path.hpp"
#include "kiln/state.hpp"

namespace kiln {

BuildReport run_build(Vfs& vfs, const BuildOptions& options) {
  BuildReport report;
  try {
    // Phases 1-2: build file and evaluation.
    BuildDescription desc = evaluate_workspace(vfs);
    // Phases 3-5: validation, requested targets, cycles.
    Graph graph(desc, vfs);
    std::vector<bool> reachable = graph.plan(options.targets);
    // Phases 6-8: state, execution, state write-back.
    BuildState state = BuildState::load(vfs);
    ScheduleResult sched = run_schedule(desc, graph, reachable, vfs, state, options.workers);
    vfs.write(kStateFile, state.serialize());
    report.events = std::move(sched.events);
    report.ran = sched.ran;
    report.hits = sched.hits;
    report.time = sched.time;
    report.error = std::move(sched.error);
  } catch (const Error& e) {
    report.error = e;
  }
  return report;
}

}  // namespace kiln

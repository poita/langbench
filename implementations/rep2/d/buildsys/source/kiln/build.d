/**
 * One complete `build`: evaluation, graph validation, scheduling and the
 * state-file update.
 */
module kiln.build;

import kiln.errors;
import kiln.graph;
import kiln.interp;
import kiln.paths;
import kiln.scheduler;
import kiln.state;
import kiln.vfs;

public import kiln.scheduler : Event, EventKind;

/// The result of one build.
struct BuildReport
{
    /// True when the build finished without an error.
    bool ok;
    /// The error that stopped the build, when `ok` is false.
    KilnError error;
    /// Events sorted by start time then step serial; empty for
    /// configuration errors.
    Event[] events;
    /// Commands executed successfully.
    int ran;
    /// Cache hits.
    int hits;
    /// Completion time of the simulated build.
    long time;
}

/// The name of the root build file.
enum rootBuildFile = "main.kiln";

/**
 * Runs a build against `vfs`.
 *
 * Params:
 *   vfs = the workspace; commands write their outputs and `.kiln-state` into it
 *   targets = requested targets (paths or `@phony`); empty means the defaults
 *   workers = number of simulated workers, at least 1
 *
 * Configuration errors leave the workspace untouched. Execution errors still
 * update `.kiln-state`. Neither throws: both are reported in the result.
 */
BuildReport runBuild(Vfs vfs, const(string)[] targets = null, int workers = 1)
{
    BuildReport rep;
    Graph graph;
    Evaluator ev;
    bool[] reach;
    try
    {
        if (!vfs.exists(rootBuildFile))
            throw new KilnError("E_NO_BUILD_FILE", rootBuildFile);
        ev = new Evaluator(vfs);
        ev.run(rootBuildFile);
        graph = new Graph(ev, vfs);
        auto roots = graph.requested(targets);
        reach = graph.reachable(roots);
    }
    catch (KilnError e)
    {
        rep.error = e;
        return rep;
    }

    auto state = parseState(vfs);
    auto result = schedule(graph, reach, ev.steps, vfs, state, workers < 1 ? 1 : workers);
    vfs.write(stateFileName, renderState(state));

    rep.events = result.events;
    rep.ran = result.ran;
    rep.hits = result.hits;
    rep.time = result.time;
    rep.error = result.error;
    rep.ok = result.error is null;
    return rep;
}

/**
 * One complete `build`: evaluate the build files, validate and resolve the
 * graph, run the scheduler against the workspace and persist the state.
 */
module kiln.build;

import kiln.errors : KilnError, fail;
import kiln.eval : Interpreter, mainBuildFile;
import kiln.graph : Graph;
import kiln.scheduler : Event, schedule;
import kiln.state : parseState, renderState;
import kiln.workspace : Workspace, stateFileName;

/// What a build did.
struct BuildReport
{
    /// True when the build reached its execution phase (so `.kiln-state` was written).
    bool executed;
    /// The error that ended the build, or null on success.
    KilnError error;
    /// Execution events, ordered by (start time, step serial).
    Event[] events;
    /// Commands that ran successfully, cache hits, and the completion time.
    long ran;
    long hits;
    long time;

    /// Whether the build succeeded.
    bool ok() const @safe pure nothrow @nogc
    {
        return error is null;
    }
}

/**
 * Runs one build in `ws`.
 *
 * Params:
 *   ws = the workspace; mutated by the build
 *   targets = requested targets (`path` or `@phony`); empty means the default list
 *   workers = the number of simulated workers (at least 1)
 */
BuildReport runBuild(Workspace ws, const(string)[] targets, int workers) @safe
{
    BuildReport report;
    Graph graph;
    int[] reach;
    try
    {
        if (!ws.exists(mainBuildFile))
            fail("E_NO_BUILD_FILE", mainBuildFile);
        auto plan = new Interpreter(ws).evaluate();
        graph = new Graph(plan, ws);
        const(string)[] wanted = targets;
        if (wanted.length == 0)
            wanted = plan.defaults;
        if (wanted.length == 0)
            throw new KilnError("E_NO_DEFAULT", "", false);
        auto roots = graph.resolveTargets(wanted);
        reach = graph.reachable(roots);

        // Execution phase: from here the state file is always written.
        report.executed = true;
        auto state = parseState(ws.find(stateFileName) is null ? "" : ws.read(stateFileName));
        auto result = schedule(graph, plan, reach, workers < 1 ? 1 : workers, ws, state);
        ws.write(stateFileName, renderState(state));
        report.events = result.events;
        report.ran = result.ran;
        report.hits = result.hits;
        report.time = result.time;
        report.error = result.error;
    }
    catch (KilnError e)
    {
        report.error = e;
    }
    return report;
}

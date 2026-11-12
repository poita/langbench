/**
 * The deterministic scheduling simulation, and the `runBuild` entry point that
 * strings together evaluation, graph validation, scheduling and state writing.
 */
module kiln.scheduler;

import kiln.commands;
import kiln.errors;
import kiln.eval;
import kiln.graph;
import kiln.state;
import kiln.step;
import kiln.vfs;

/// One line of a build's event log.
struct Event
{
    /// What happened to the step.
    enum Kind : ubyte { hit, run, fail, cancel }

    ///
    Kind kind;
    /// Step serial (used only for ordering).
    int serial;
    /// Start time (the time of the hit for `hit`).
    long start;
    /// End time (equal to `start` for `hit`).
    long end;
    ///
    int worker;
    /// The step's primary output.
    string target;
    /// The canonical command string.
    string command;
}

/// The outcome of one `build`.
final class BuildResult
{
    /// The error that ended the build, or null if it succeeded.
    KilnError error;
    /// Events sorted by start time, then serial.
    Event[] events;
    /// Number of commands executed successfully.
    int ran;
    /// Number of cache hits.
    int hits;
    /// Completion time.
    long time;

    /// True if the build finished without error.
    bool ok() const @safe pure nothrow @nogc { return error is null; }
}

/// A binary min-heap of ints.
private struct MinHeap
{
    private int[] a;

    bool empty() const @safe pure nothrow @nogc { return a.length == 0; }

    void push(int v) @safe pure nothrow
    {
        a ~= v;
        size_t i = a.length - 1;
        while (i > 0)
        {
            const p = (i - 1) / 2;
            if (a[p] <= a[i])
                break;
            const t = a[p];
            a[p] = a[i];
            a[i] = t;
            i = p;
        }
    }

    int pop() @safe pure nothrow
    {
        const top = a[0];
        a[0] = a[$ - 1];
        a = a[0 .. $ - 1];
        size_t i = 0;
        while (true)
        {
            const l = 2 * i + 1, r = l + 1;
            size_t m = i;
            if (l < a.length && a[l] < a[m])
                m = l;
            if (r < a.length && a[r] < a[m])
                m = r;
            if (m == i)
                break;
            const t = a[m];
            a[m] = a[i];
            a[i] = t;
            i = m;
        }
        return top;
    }
}

private struct Running
{
    bool busy;
    int serial;
    long start, end;
    size_t event;
    Execution exec;
}

/**
 * Runs one build against `fs`.
 *
 * Params:
 *   fs = the workspace; outputs and `.kiln-state` are written into it
 *   targets = the requested targets (empty: the default targets)
 *   workers = the number of simulated workers (at least 1)
 */
BuildResult runBuild(Vfs fs, const(string)[] targets, int workers)
{
    auto result = new BuildResult;
    Evaluation ev;
    Graph graph;
    bool[] reach;
    int[] roots;
    try
    {
        ev = evaluateWorkspace(fs);
        graph = new Graph(ev, fs);
        graph.validate(ev.defaults);
        reach = graph.reachable(targets, ev.defaults, roots);
    }
    catch (KilnError e)
    {
        result.error = e;
        return result;
    }

    auto state = State.parse(fs.read(stateFilePath));
    auto sched = new Scheduler(fs, graph, reach, state, workers, result);
    sched.run();
    fs.write(stateFilePath, state.serialize());

    import std.algorithm.sorting : sort;

    result.events.sort!((a, b) => a.start != b.start ? a.start < b.start : a.serial < b.serial);
    return result;
}

private final class Scheduler
{
    Vfs fs;
    Graph graph;
    State state;
    BuildResult result;
    int workers;
    int[] pending;
    int[][] dependents;
    MinHeap undecided, stale;
    Running[] running;
    long time;
    long completion;

    this(Vfs fs, Graph graph, bool[] reach, State state, int workers, BuildResult result)
    {
        this.fs = fs;
        this.graph = graph;
        this.state = state;
        this.workers = workers;
        this.result = result;
        const n = graph.nodes.length;
        pending = new int[n];
        dependents = new int[][n];
        foreach (id; 0 .. n)
        {
            if (!reach[id])
                continue;
            pending[id] = cast(int) graph.nodes[id].successors.length;
            foreach (m; graph.nodes[id].successors)
                dependents[m] ~= cast(int) id;
        }
        running = new Running[workers];
        // Instant nodes: sources and phonies without dependencies complete at time 0.
        int[] initial;
        foreach (id; 0 .. n)
            if (reach[id] && pending[id] == 0)
                initial ~= cast(int) id;
        foreach (id; initial)
        {
            if (graph.nodes[id].kind == NodeKind.step)
                undecided.push(id);
            else
                complete(id);
        }
    }

    /// Completes `node`; sources and phonies cascade, steps that become ready are queued.
    void complete(int node)
    {
        int[] work = [node];
        while (work.length)
        {
            const n = work[$ - 1];
            work = work[0 .. $ - 1];
            foreach (d; dependents[n])
            {
                if (--pending[d] != 0)
                    continue;
                if (graph.nodes[d].kind == NodeKind.step)
                    undecided.push(d);
                else
                    work ~= d;
            }
        }
    }

    void run()
    {
        while (true)
        {
            // (A) settle cache hits at the current time
            while (!undecided.empty)
            {
                const serial = undecided.pop();
                auto step = graph.steps[serial];
                if (state.isFresh(step, fs))
                {
                    ++result.hits;
                    result.events ~= Event(Event.Kind.hit, serial, time, time, 0, step.primary, step.cmdString);
                    if (time > completion)
                        completion = time;
                    complete(serial);
                }
                else
                    stale.push(serial);
            }

            // (B) dispatch
            while (!stale.empty)
            {
                int w = -1;
                foreach (i; 0 .. workers)
                    if (!running[i].busy)
                    {
                        w = i;
                        break;
                    }
                if (w < 0)
                    break;
                const serial = stale.pop();
                auto step = graph.steps[serial];
                const end = time + step.cost;
                result.events ~= Event(Event.Kind.run, serial, time, end, w, step.primary, step.cmdString);
                if (end > completion)
                    completion = end;
                running[w] = Running(true, serial, time, end, result.events.length - 1, executeCommand(step, fs));
            }

            // (C) advance the clock
            long next = long.max;
            foreach (ref r; running)
                if (r.busy && r.end < next)
                    next = r.end;
            if (next == long.max)
                break;
            time = next;
            int[] finished;
            int[] failed;
            foreach (w; 0 .. workers)
            {
                if (!running[w].busy || running[w].end != time)
                    continue;
                auto r = &running[w];
                r.busy = false;
                finished ~= cast(int) w;
                auto step = graph.steps[r.serial];
                if (r.exec.error !is null)
                {
                    result.events[r.event].kind = Event.Kind.fail;
                    failed ~= cast(int) w;
                }
                else
                {
                    commit(step, r.exec);
                    ++result.ran;
                }
            }
            if (failed.length)
            {
                int bestSerial = int.max;
                foreach (w; failed)
                    if (running[w].serial < bestSerial)
                    {
                        bestSerial = running[w].serial;
                        result.error = running[w].exec.error;
                    }
                foreach (w; 0 .. workers)
                {
                    if (running[w].busy)
                    {
                        result.events[running[w].event].kind = Event.Kind.cancel;
                        state.entries.remove(graph.steps[running[w].serial].primary);
                    }
                }
                foreach (w; failed)
                    state.entries.remove(graph.steps[running[w].serial].primary);
                break;
            }
            foreach (w; finished)
                complete(running[w].serial);
        }
        result.time = completion;
    }

    /// Writes a successful step's outputs and replaces its state entry.
    void commit(Step step, Execution ex)
    {
        StateEntry e;
        e.key = step.primary;
        e.cmd = step.cmdString;
        foreach (i, p; step.fileInputs)
            e.ins ~= PathHash(p, ex.inputHashes[i]);
        foreach (i, p; ex.deps)
            e.deps ~= PathHash(p, ex.depHashes[i]);
        foreach (i, p; step.fullOuts)
        {
            fs.write(p, ex.outputs[i]);
            e.outs ~= PathHash(p, fs.get(p).hash);
        }
        state.entries[e.key] = e;
    }
}

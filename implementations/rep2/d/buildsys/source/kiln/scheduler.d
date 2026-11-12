/**
 * The deterministic scheduling simulation.
 *
 * An event-driven simulation of `N` workers: ready steps are taken lowest
 * serial first from priority queues (O(log R) per operation), freshness is
 * decided when a step becomes ready, and the clock jumps from one completion
 * to the next. Commands run against the virtual file system.
 */
module kiln.scheduler;

import kiln.commands : CommandResult, runCommand;
import kiln.errors : KilnError;
import kiln.graph : Graph, NodeKind;
import kiln.model : BuildPlan, Step;
import kiln.state : BuildState, HashedPath, StateEntry, isFresh;
import kiln.workspace : Workspace;

/// What happened to a step.
enum EventKind : ubyte
{
    hit, /// cache hit
    run, /// executed successfully
    fail, /// execution error
    cancel, /// dispatched but still running when the build aborted
}

/// One log event of a build.
struct Event
{
    EventKind kind;
    int serial;
    long start;
    long end;
    int worker;
    string target;
    string command;
}

/// The outcome of the execution phase.
struct ScheduleResult
{
    Event[] events; // sorted by (start, serial)
    long ran;
    long hits;
    long time;
    /// The reported execution error, or null.
    KilnError error;
}

/// A binary min-heap of step serials.
private struct MinHeap
{
    private int[] a;

    bool empty() const @safe pure nothrow @nogc
    {
        return a.length == 0;
    }

    void push(int v) @safe pure nothrow
    {
        a ~= v;
        size_t i = a.length - 1;
        while (i > 0)
        {
            immutable p = (i - 1) / 2;
            if (a[p] <= a[i])
                break;
            immutable t = a[p];
            a[p] = a[i];
            a[i] = t;
            i = p;
        }
    }

    int pop() @safe pure nothrow
    {
        immutable top = a[0];
        a[0] = a[$ - 1];
        a.length -= 1;
        size_t i = 0;
        while (true)
        {
            immutable l = 2 * i + 1, r = l + 1;
            size_t m = i;
            if (l < a.length && a[l] < a[m])
                m = l;
            if (r < a.length && a[r] < a[m])
                m = r;
            if (m == i)
                break;
            immutable t = a[m];
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
    int step;
    long start;
    long end;
    size_t eventIndex;
}

/**
 * Simulates the build of the nodes in `reach` on `workers` workers,
 * updating `ws` and `state` as commands complete.
 */
ScheduleResult schedule(Graph graph, BuildPlan plan, const(int)[] reach, int workers,
        Workspace ws, BuildState state) @safe
{
    ScheduleResult res;
    auto nodes = graph.nodes;

    // Pending counts and reverse edges over the reachable set.
    auto pending = new size_t[nodes.length];
    auto dependents = new int[][nodes.length];
    foreach (n; reach)
    {
        pending[n] = nodes[n].successors.length;
        foreach (m; nodes[n].successors)
            dependents[m] ~= n;
    }

    MinHeap undecided, staleReady;

    // Completes node `n`; steps that become ready join `undecided`, and
    // phony nodes whose last dependency just completed complete at once.
    void complete(int n) @safe
    {
        int[] work = [n];
        while (work.length)
        {
            immutable c = work[$ - 1];
            work = work[0 .. $ - 1];
            foreach (d; dependents[c])
            {
                if (--pending[d] != 0)
                    continue;
                if (nodes[d].kind == NodeKind.step)
                    undecided.push(d);
                else
                    work ~= d;
            }
        }
    }

    foreach (n; reach)
        if (nodes[n].kind == NodeKind.step && pending[n] == 0)
            undecided.push(n);
    foreach (n; reach)
    {
        if (nodes[n].kind == NodeKind.source)
            complete(n);
        else if (nodes[n].kind == NodeKind.phony && nodes[n].successors.length == 0)
            complete(n);
    }

    auto running = new Running[workers];
    long time = 0;
    long maxTime = 0;

    while (true)
    {
        // (A) settle cache hits at the current time.
        while (!undecided.empty)
        {
            immutable n = undecided.pop();
            auto step = plan.steps[n];
            auto entry = step.primary in state.entries;
            if (isFresh(step, entry, ws))
            {
                res.hits++;
                res.events ~= Event(EventKind.hit, n, time, time, 0, step.primary, step.cmdString);
                if (time > maxTime)
                    maxTime = time;
                complete(n);
            }
            else
            {
                staleReady.push(n);
            }
        }

        // (B) dispatch onto the lowest-numbered free workers.
        foreach (w; 0 .. workers)
        {
            if (staleReady.empty)
                break;
            if (running[w].busy)
                continue;
            immutable n = staleReady.pop();
            auto step = plan.steps[n];
            immutable end = time + step.effectiveCost;
            res.events ~= Event(EventKind.run, n, time, end, w, step.primary, step.cmdString);
            running[w] = Running(true, n, time, end, res.events.length - 1);
            if (end > maxTime)
                maxTime = end;
        }

        // (C) advance the clock.
        bool any = false;
        long next = long.max;
        foreach (ref r; running)
            if (r.busy)
            {
                any = true;
                if (r.end < next)
                    next = r.end;
            }
        if (!any)
            break;
        time = next;

        int[] failedSteps;
        KilnError[int] errors;
        int[] finished;
        foreach (w; 0 .. workers)
        {
            if (!running[w].busy || running[w].end != time)
                continue;
            immutable n = running[w].step;
            immutable ei = running[w].eventIndex;
            running[w].busy = false;
            auto step = plan.steps[n];
            try
            {
                auto result = runCommand(step, ws);
                commit(step, result, ws, state);
                res.ran++;
                finished ~= n;
            }
            catch (KilnError e)
            {
                res.events[ei].kind = EventKind.fail;
                failedSteps ~= n;
                errors[n] = e;
            }
        }
        if (failedSteps.length)
        {
            int best = failedSteps[0];
            foreach (n; failedSteps)
                if (n < best)
                    best = n;
            res.error = errors[best];
            foreach (w; 0 .. workers)
            {
                if (!running[w].busy)
                    continue;
                res.events[running[w].eventIndex].kind = EventKind.cancel;
                state.remove(plan.steps[running[w].step].primary);
            }
            foreach (n; failedSteps)
                state.remove(plan.steps[n].primary);
            break;
        }
        foreach (n; finished)
            complete(n);
    }

    res.time = maxTime;
    sortEvents(res.events);
    return res;
}

/// Writes a successful command's outputs and records its state entry.
private void commit(const Step step, ref CommandResult result, Workspace ws, BuildState state) @safe
{
    StateEntry e;
    e.cmd = step.cmdString;
    foreach (p; step.fileInputs)
    {
        ulong h;
        ws.hashOf(p, h);
        e.ins ~= HashedPath(p, h);
    }
    foreach (p; result.discovered)
    {
        ulong h;
        ws.hashOf(p, h);
        e.deps ~= HashedPath(p, h);
    }
    foreach (k, p; step.fullOuts)
    {
        ws.write(p, result.outputs[k]);
        ulong h;
        ws.hashOf(p, h);
        e.outs ~= HashedPath(p, h);
    }
    state.put(step.primary, e);
}

private void sortEvents(Event[] events) @safe pure nothrow
{
    import std.algorithm.sorting : sort;

    events.sort!((a, b) => a.start != b.start ? a.start < b.start : a.serial < b.serial);
}

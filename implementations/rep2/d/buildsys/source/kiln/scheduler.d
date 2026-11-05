/**
 * The deterministic scheduling simulation: ready heaps, a fixed set of
 * workers, a simulated clock, cache-hit settling, failure and cancellation.
 */
module kiln.scheduler;

import kiln.commands;
import kiln.errors;
import kiln.graph;
import kiln.hash;
import kiln.state;
import kiln.step;
import kiln.vfs;

import std.algorithm : sort;

/// Kinds of build event.
enum EventKind : ubyte
{
    hit,
    run,
    fail,
    cancel,
}

/// One line of a build's event log.
struct Event
{
    EventKind kind;
    /// Start time (the time itself for a hit).
    long start;
    long end;
    int worker;
    /// Serial of the step; orders events that start together.
    int serial;
    /// The step's primary output path.
    string target;
    /// The step's canonical command string (empty for a hit).
    string command;
}

/// The outcome of the scheduling phase.
struct ScheduleResult
{
    /// Events sorted by start time, then serial.
    Event[] events;
    int ran;
    int hits;
    /// Completion time of the build.
    long time;
    /// Non-null when an execution error aborted the build.
    KilnError error;
}

private struct MinHeap
{
    int[] a;

    bool empty() const
    {
        return a.length == 0;
    }

    void push(int v)
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

    int pop()
    {
        immutable top = a[0];
        a[0] = a[$ - 1];
        a.length = a.length - 1;
        size_t i = 0;
        for (;;)
        {
            size_t l = 2 * i + 1, r = l + 1, m = i;
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
    int serial;
    long start, end;
    size_t eventIndex;
    CommandResult result;
    KilnError error;
    ulong[] inHashes;
}

/**
 * Simulates the build of the reachable set on `workers` workers.
 *
 * `state` is updated in place: entries of steps that ran are replaced, those
 * of failed or cancelled steps removed.
 */
ScheduleResult schedule(Graph g, const(bool)[] reach, Step[] steps, Vfs vfs, ref State state, int workers)
{
    ScheduleResult res;
    immutable n = g.kind.length;
    auto dependents = new int[][n];
    auto pending = new int[n];
    foreach (node; 0 .. n)
    {
        if (!reach[node])
            continue;
        pending[node] = cast(int) g.succ[node].length;
        foreach (m; g.succ[node])
            dependents[m] ~= cast(int) node;
    }

    MinHeap undecided, stale;
    int[] roots;
    foreach (node; 0 .. n)
    {
        if (!reach[node])
            continue;
        if (g.kind[node] == NodeKind.step)
        {
            if (pending[node] == 0)
                undecided.push(cast(int) node);
        }
        else if (g.kind[node] == NodeKind.source || pending[node] == 0)
            roots ~= cast(int) node;
    }

    void complete(int start)
    {
        int[] work = [start];
        while (work.length)
        {
            immutable x = work[$ - 1];
            work.length = work.length - 1;
            foreach (d; dependents[x])
            {
                if (--pending[d] != 0)
                    continue;
                if (g.kind[d] == NodeKind.step)
                    undecided.push(d);
                else
                    work ~= d;
            }
        }
    }

    foreach (r; roots)
        complete(r);

    auto running = new Running[workers];
    long time = 0;

    for (;;)
    {
        // (A) settle cache hits at the current time
        while (!undecided.empty)
        {
            immutable id = undecided.pop();
            auto step = steps[id];
            auto entry = step.primary in state;
            if (isFresh(entry ? *entry : null, step, vfs))
            {
                res.hits++;
                res.events ~= Event(EventKind.hit, time, time, 0, id, step.primary, step.canon);
                complete(id);
            }
            else
                stale.push(id);
        }

        // (B) dispatch
        while (!stale.empty)
        {
            int w = -1;
            foreach (k; 0 .. workers)
                if (!running[k].busy)
                {
                    w = k;
                    break;
                }
            if (w < 0)
                break;
            immutable id = stale.pop();
            auto step = steps[id];
            auto r = &running[w];
            *r = Running.init;
            r.busy = true;
            r.serial = id;
            r.start = time;
            r.end = time + step.cost;
            auto contents = new string[step.fileInputs.length];
            r.inHashes = new ulong[step.fileInputs.length];
            foreach (i, p; step.fileInputs)
            {
                contents[i] = vfs.read(p);
                r.inHashes[i] = vfs.hashOf(p);
            }
            try
                r.result = runCommand(step, contents, vfs);
            catch (KilnError e)
                r.error = e;
            r.eventIndex = res.events.length;
            res.events ~= Event(EventKind.run, time, r.end, w, id, step.primary, step.canon);
        }

        // (C) advance the clock
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
        int[] finished;
        KilnError firstError;
        int firstErrorSerial = int.max;
        foreach (w; 0 .. workers)
        {
            auto r = &running[w];
            if (!r.busy || r.end != time)
                continue;
            r.busy = false;
            auto step = steps[r.serial];
            if (r.error !is null)
            {
                res.events[r.eventIndex].kind = EventKind.fail;
                state.remove(step.primary);
                if (r.serial < firstErrorSerial)
                {
                    firstErrorSerial = r.serial;
                    firstError = r.error;
                }
            }
            else
            {
                auto e = new StateEntry;
                e.cmd = step.canon;
                foreach (i, p; step.fileInputs)
                    e.ins ~= HashedPath(p, r.inHashes[i]);
                foreach (i, p; r.result.depPaths)
                    e.deps ~= HashedPath(p, r.result.depHashes[i]);
                foreach (i, p; step.fullOutputs)
                {
                    immutable h = fnv1a(r.result.outputs[i]);
                    vfs.writeWithHash(p, r.result.outputs[i], h);
                    e.outs ~= HashedPath(p, h);
                }
                state[step.primary] = e;
                res.ran++;
            }
            finished ~= r.serial;
        }
        if (firstError !is null)
        {
            foreach (w; 0 .. workers)
                if (running[w].busy)
                {
                    res.events[running[w].eventIndex].kind = EventKind.cancel;
                    state.remove(steps[running[w].serial].primary);
                }
            res.error = firstError;
            break;
        }
        foreach (id; finished)
            complete(id);
    }

    foreach (ref e; res.events)
        if (e.end > res.time)
            res.time = e.end;
    res.events.sort!((a, b) => a.start < b.start || (a.start == b.start && a.serial < b.serial));
    return res;
}

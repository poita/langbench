/// A single `build`: configuration phases, then the simulated scheduler.
module kiln.build;

import std.algorithm.sorting : sort;
import kiln.bytes;
import kiln.commands;
import kiln.errors;
import kiln.graph;
import kiln.hash : fnv1a;
import kiln.heap;
import kiln.interp : evaluateBuild;
import kiln.paths : stateFilePath;
import kiln.plan;
import kiln.state;
import kiln.vfs;

/// What happened to a step in a build.
enum EventKind : ubyte { hit, run, fail, cancel }

/// One log event of a build.
struct Event
{
    EventKind kind;
    int serial;
    long start;
    long end;       /// equal to `start` for hits
    int worker;
    string target;  /// primary output path
    string command; /// canonical command string (empty for hits)
}

/// The outcome of a build.
struct BuildReport
{
    /// Events sorted by start time, then step serial.
    Event[] events;
    /// Non-null when the build failed (configuration or execution error).
    KilnError error;
    int ran;
    int hits;
    long time;

    /// True when the build succeeded.
    @property bool ok() const
    {
        return error is null;
    }
}

private struct Running
{
    bool busy;
    int step;
    long start;
    long end;
    int eventIndex;
    CmdResult result;
    ReadFile[] inputs;
}

/// Run a build against `vfs`. `targets` are the requested targets (empty
/// means the default list) and `workers` the simulated worker count.
/// Mutates `vfs` (command outputs and `.kiln-state`).
BuildReport runBuild(Vfs vfs, string[] targets, int workers)
{
    BuildReport rep;
    Graph g;
    Plan plan;
    try
    {
        plan = evaluateBuild(vfs);
        g = buildGraph(plan, vfs, targets);
    }
    catch (KilnError e)
    {
        rep.error = e;
        return rep;
    }

    State state = parseState(vfs.read(stateFilePath));
    if (state is null)
        state = State.init;
    State work = state.dup; // entries to be written back

    immutable nodeCount = g.nodes.length;
    // pending counts and dependents (reachable nodes only)
    auto pending = new int[nodeCount];
    auto dependents = new int[][nodeCount];
    foreach (n; 0 .. nodeCount)
    {
        if (!g.reachable[n])
            continue;
        pending[n] = cast(int) g.nodes[n].succ.length;
        foreach (s; g.nodes[n].succ)
            dependents[s] ~= cast(int) n;
    }

    MinHeap undecided, stale;
    long time = 0;

    // completing a node cascades through sources and phonies
    void complete(int n)
    {
        int[] work_ = [n];
        while (work_.length)
        {
            immutable cur = work_[$ - 1];
            work_.length = work_.length - 1;
            foreach (d; dependents[cur])
            {
                if (--pending[d] == 0)
                {
                    if (g.nodes[d].kind == NodeKind.step)
                        undecided.push(d);
                    else
                        work_ ~= d;
                }
            }
        }
    }

    // initialisation
    foreach (n; 0 .. nodeCount)
    {
        if (!g.reachable[n] || pending[n] != 0)
            continue;
        if (g.nodes[n].kind == NodeKind.step)
            undecided.push(cast(int) n);
    }
    foreach (n; 0 .. nodeCount)
        if (g.reachable[n] && pending[n] == 0 && g.nodes[n].kind != NodeKind.step)
            complete(cast(int) n);

    auto running = new Running[workers];
    long maxTime = 0;
    KilnError execError;

    loop: while (true)
    {
        // (A) settle cache hits at the current time
        while (!undecided.empty)
        {
            immutable n = undecided.pop();
            auto step = plan.steps[n];
            auto entry = step.primary in state;
            if (isFresh(entry, step, vfs))
            {
                ++rep.hits;
                rep.events ~= Event(EventKind.hit, n, time, time, -1, step.primary, null);
                if (time > maxTime)
                    maxTime = time;
                complete(n);
            }
            else
                stale.push(n);
        }
        // (B) dispatch
        while (!stale.empty)
        {
            int w = -1;
            foreach (i; 0 .. running.length)
                if (!running[i].busy)
                {
                    w = cast(int) i;
                    break;
                }
            if (w < 0)
                break;
            immutable n = stale.pop();
            auto step = plan.steps[n];
            auto r = &running[w];
            r.busy = true;
            r.step = n;
            r.start = time;
            r.end = time + step.cost;
            // capture every input now
            r.inputs.length = 0;
            foreach (p; step.fileInputs)
                r.inputs ~= ReadFile(p, vfs.read(p), vfs.hashOf(p));
            r.result = runCommand(step.spec.name, step.args, r.inputs, vfs);
            r.eventIndex = cast(int) rep.events.length;
            rep.events ~= Event(EventKind.run, n, r.start, r.end, w, step.primary, step.canon);
            if (r.end > maxTime)
                maxTime = r.end;
        }
        // (C) advance the clock
        long next = long.max;
        bool any = false;
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
        int[] failed;
        int[] completed;
        foreach (w; 0 .. running.length)
        {
            auto r = &running[w];
            if (!r.busy || r.end != time)
                continue;
            r.busy = false;
            auto step = plan.steps[r.step];
            if (r.result.error !is null)
            {
                rep.events[r.eventIndex].kind = EventKind.fail;
                failed ~= cast(int) w;
                continue;
            }
            commitStep(vfs, step, *r, work);
            ++rep.ran;
            completed ~= r.step;
        }
        if (failed.length)
        {
            // the smallest-serial failing step supplies the error
            int best = -1;
            foreach (w; failed)
                if (best < 0 || running[w].step < running[best].step)
                    best = w;
            execError = running[best].result.error;
            foreach (w; failed)
                work.remove(plan.steps[running[w].step].primary);
            foreach (ref r; running)
                if (r.busy)
                {
                    rep.events[r.eventIndex].kind = EventKind.cancel;
                    work.remove(plan.steps[r.step].primary);
                    r.busy = false;
                }
            break loop;
        }
        foreach (n; completed)
            complete(n);
    }

    vfs.write(stateFilePath, writeState(work));
    rep.error = execError;
    rep.time = maxTime;
    sortEvents(rep.events);
    return rep;
}

private void sortEvents(ref Event[] ev)
{
    ev.sort!((a, b) => a.start != b.start ? a.start < b.start : a.serial < b.serial);
}

/// Write a successful step's outputs into the workspace and replace its entry.
private void commitStep(Vfs vfs, StepDef step, ref Running r, ref State work)
{
    Entry e;
    e.key = step.primary;
    e.cmd = step.canon;
    foreach (ref f; r.inputs)
        e.ins ~= PathHash(f.path, f.hash);
    foreach (ref d; r.result.discovered)
        e.deps ~= PathHash(d.path, d.hash);
    auto h = fnv1a(r.result.output);
    vfs.writeHashed(step.primary, r.result.output, h);
    e.outs ~= PathHash(step.primary, h);
    if (step.hasDepfile)
    {
        auto dh = fnv1a(r.result.depfileContent);
        vfs.writeHashed(step.depfile, r.result.depfileContent, dh);
        e.outs ~= PathHash(step.depfile, dh);
    }
    work[step.primary] = e;
}

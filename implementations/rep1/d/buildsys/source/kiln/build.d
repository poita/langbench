/// One build: configuration, scheduling simulation, execution, state update.
module kiln.build;

import std.algorithm.sorting : sort;

import kiln.commands;
import kiln.errors;
import kiln.graph;
import kiln.hash : fnv1a;
import kiln.interp;
import kiln.paths : stateFileName;
import kiln.state;
import kiln.step;
import kiln.vfs;

/// A line of build activity in the log.
struct Event
{
    /// What happened.
    enum Kind : ubyte
    {
        hit,
        run,
        fail,
        cancel
    }

    Kind kind;
    long start;
    long end;
    int worker;
    int serial;
    string target;
    string command;
}

/// Result of one `build` session step.
struct BuildReport
{
    Event[] events; /// sorted by start time, then step serial
    bool ok; /// false when `error` is set
    string error; /// rendered error (`KIND detail`) when the build failed
    long ran; /// commands that executed successfully
    long hits; /// cache hits
    long time; /// completion time
}

private struct IntHeap
{
    int[] a;

    bool empty() const @safe
    {
        return a.length == 0;
    }

    void push(int v) @safe
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

    int pop() @safe
    {
        const top = a[0];
        a[0] = a[$ - 1];
        a.length = a.length - 1;
        size_t i = 0;
        while (true)
        {
            size_t l = 2 * i + 1, r = l + 1, m = i;
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
    bool active;
    int step;
    long start, end;
    int eventIdx;
    ExecResult result;
    StateEntry entry;
    ulong[] outHashes;
}

/// Runs one build of the workspace in `vfs`.
///
/// `targets` are the requested targets (empty = the default targets) and
/// `workers` the simulated worker count. The workspace and `.kiln-state` are
/// updated exactly as the specification prescribes.
BuildReport runBuild(Vfs vfs, const(string)[] targets, int workers) @safe
{
    BuildReport rep;
    Interp ip;
    Graph g;
    try
    {
        if (!vfs.exists("main.kiln"))
            throw new KilnError("E_NO_BUILD_FILE", "main.kiln");
        ip = new Interp(vfs);
        ip.runFile("main.kiln");
        g = new Graph(ip.steps, ip.phonies, vfs);
        g.checkDuplicateOutputs();
        g.resolveReferences();
        foreach (d; ip.defaults)
            if (g.resolve(d) < 0)
                throw new KilnError("E_UNKNOWN_TARGET", d);
        const(string)[] reqNames = targets;
        if (targets.length == 0)
        {
            reqNames = ip.defaults;
            if (reqNames.length == 0)
                throw new KilnError("E_NO_DEFAULT");
        }
        int[] roots;
        bool[string] seen;
        foreach (t; reqNames)
        {
            if (t in seen)
                continue;
            seen[t] = true;
            const id = g.resolve(t);
            if (id < 0)
                throw new KilnError("E_UNKNOWN_TARGET", t);
            roots ~= id;
        }
        auto cycle = g.findCycle(roots);
        if (cycle !is null)
        {
            string text;
            foreach (i, n; cycle)
                text ~= (i ? " -> " : "") ~ n;
            throw new KilnError("E_CYCLE", text);
        }
    }
    catch (KilnError e)
    {
        rep.error = e.render;
        return rep;
    }

    State state;
    if (vfs.exists(stateFileName))
        state = parseState(vfs.content(stateFileName));
    schedule(rep, ip.steps, g, state, vfs, workers);
    vfs.put(stateFileName, renderState(state));
    return rep;
}

private void schedule(ref BuildReport rep, Step[] steps, Graph g, ref State state, Vfs vfs, int nWorkers) @safe
{
    const nNodes = g.length;
    auto pending = new int[](nNodes);
    auto dependents = new int[][](nNodes);
    foreach (n; 0 .. nNodes)
    {
        if (!g.colour[n])
            continue;
        pending[n] = cast(int) g.succ[n].length;
        foreach (m; g.succ[n])
            dependents[m] ~= cast(int) n;
    }

    IntHeap undecided, stale;

    void complete(int n)
    {
        int[] work = [n];
        while (work.length)
        {
            const x = work[$ - 1];
            work.length = work.length - 1;
            foreach (d; dependents[x])
            {
                if (--pending[d] == 0)
                {
                    if (g.kinds[d] == Graph.Kind.step)
                        undecided.push(d);
                    else
                        work ~= d;
                }
            }
        }
    }

    // initialisation: steps with nothing to wait for, then instant nodes
    foreach (n; 0 .. nNodes)
        if (g.colour[n] && g.kinds[n] == Graph.Kind.step && pending[n] == 0)
            undecided.push(cast(int) n);
    int[] instant;
    foreach (n; 0 .. nNodes)
        if (g.colour[n] && g.kinds[n] != Graph.Kind.step
                && (g.kinds[n] == Graph.Kind.source || pending[n] == 0))
            instant ~= cast(int) n;
    foreach (n; instant)
        complete(n);

    auto running = new Running[](nWorkers);
    long time = 0;
    Event[] events;
    long ran = 0, hits = 0;
    KilnError buildError;

    while (true)
    {
        // (A) settle cache hits
        while (!undecided.empty)
        {
            const n = undecided.pop();
            auto st = steps[n];
            auto e = st.primary in state;
            if (isFresh(st, e, vfs))
            {
                ++hits;
                events ~= Event(Event.Kind.hit, time, time, 0, st.serial, st.primary, st.canonical);
                complete(n);
            }
            else
                stale.push(n);
        }

        // (B) dispatch
        while (!stale.empty)
        {
            int w = -1;
            foreach (i; 0 .. nWorkers)
                if (!running[i].active)
                {
                    w = i;
                    break;
                }
            if (w < 0)
                break;
            const n = stale.pop();
            auto st = steps[n];
            auto r = &running[w];
            *r = Running.init;
            r.active = true;
            r.step = n;
            r.start = time;
            r.end = time + st.cost;
            r.eventIdx = cast(int) events.length;
            events ~= Event(Event.Kind.run, r.start, r.end, w, st.serial, st.primary, st.canonical);
            dispatch(*r, st, vfs);
        }

        // (C) advance the clock
        long next = long.max;
        bool any = false;
        foreach (ref r; running)
            if (r.active)
            {
                any = true;
                if (r.end < next)
                    next = r.end;
            }
        if (!any)
            break;
        time = next;
        int[] failed;
        int[] done;
        foreach (w; 0 .. nWorkers)
        {
            auto r = &running[w];
            if (!r.active || r.end != time)
                continue;
            r.active = false;
            if (!r.result.ok)
            {
                events[r.eventIdx].kind = Event.Kind.fail;
                failed ~= w;
                continue;
            }
            auto st = steps[r.step];
            foreach (i, p; st.fullOutputs)
                vfs.putHashed(p, r.result.outputs[i], r.outHashes[i]);
            state[st.primary] = r.entry;
            ++ran;
            done ~= w;
        }
        if (failed.length)
        {
            int best = -1;
            foreach (w; failed)
                if (best < 0 || steps[running[w].step].serial < steps[running[best].step].serial)
                    best = w;
            buildError = running[best].result.error;
            foreach (w; 0 .. nWorkers)
            {
                if (!running[w].active)
                    continue;
                events[running[w].eventIdx].kind = Event.Kind.cancel;
                state.remove(steps[running[w].step].primary);
            }
            foreach (w; failed)
                state.remove(steps[running[w].step].primary);
            break;
        }
        foreach (w; done)
            complete(running[w].step);
    }

    long total = 0;
    foreach (ref e; events)
        if (e.end > total)
            total = e.end;
    events.sort!((a, b) => a.start != b.start ? a.start < b.start : a.serial < b.serial);
    rep.events = events;
    rep.ran = ran;
    rep.hits = hits;
    rep.time = total;
    if (buildError !is null)
        rep.error = buildError.render;
    else
        rep.ok = true;
}

/// Reads the step's inputs at its start time and computes its result and the
/// state entry it will record; nothing is written to the workspace yet.
private void dispatch(ref Running r, Step st, Vfs vfs) @safe
{
    auto contents = new string[](st.fileInputs.length);
    StateItem[] ins;
    ins.reserve(st.fileInputs.length);
    foreach (i, p; st.fileInputs)
    {
        contents[i] = vfs.content(p);
        ins ~= StateItem(p, vfs.hash(p));
    }
    r.result = executeCommand(st.cmd, st.args, st.fileInputs, contents, vfs);
    if (!r.result.ok)
        return;
    StateEntry e;
    e.cmd = st.canonical;
    e.ins = ins;
    foreach (d; r.result.deps)
        e.deps ~= StateItem(d, vfs.hash(d));
    r.outHashes = new ulong[](r.result.outputs.length);
    foreach (i, p; st.fullOutputs)
    {
        r.outHashes[i] = fnv1a(r.result.outputs[i]);
        e.outs ~= StateItem(p, r.outHashes[i]);
    }
    r.entry = e;
}

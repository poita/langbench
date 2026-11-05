/**
 * The dependency graph: nodes for steps, phony targets and source files,
 * whole-graph validation, target resolution and cycle detection.
 */
module kiln.graph;

import kiln.errors;
import kiln.interp;
import kiln.step;
import kiln.vfs;

/// Kinds of graph node.
enum NodeKind : ubyte
{
    step,
    phony,
    source,
}

/// The dependency graph of one build.
final class Graph
{
    /// Number of step nodes; step `n` has node id `n` (its serial).
    int numSteps;
    /// Number of phony nodes; phony `k` has node id `numSteps + k`.
    int numPhony;
    NodeKind[] kind;
    /// Node names as used in messages.
    string[] name;
    /// Successor lists (ordering dependencies, de-duplicated, first kept).
    int[][] succ;

    private Evaluator ev;
    private Vfs vfs;
    private int[string] outputOwner;
    private int[string] sourceNode;

    /**
     * Builds the graph and performs whole-graph validation.
     *
     * Throws: `E_DUP_OUTPUT`, `E_MISSING_INPUT` or `E_UNKNOWN_TARGET`.
     */
    this(Evaluator ev, Vfs vfs)
    {
        this.ev = ev;
        this.vfs = vfs;
        numSteps = cast(int) ev.steps.length;
        numPhony = cast(int) ev.phonyNames.length;
        foreach (s; ev.steps)
        {
            kind ~= NodeKind.step;
            name ~= s.primary;
        }
        foreach (p; ev.phonyNames)
        {
            kind ~= NodeKind.phony;
            name ~= "@" ~ p;
        }
        succ.length = kind.length;

        // 1. duplicate outputs
        foreach (s; ev.steps)
            foreach (o; s.fullOutputs)
            {
                if (o in outputOwner)
                    throw new KilnError("E_DUP_OUTPUT", o);
                outputOwner[o] = s.serial;
            }

        // 2. reference resolution
        foreach (s; ev.steps)
        {
            int[] deps;
            foreach (r; s.ins)
                deps ~= resolveRequired(r, s.primary);
            foreach (r; s.afters)
                deps ~= resolveRequired(r, s.primary);
            succ[s.serial] = dedup(deps);
        }
        foreach (k; 0 .. numPhony)
        {
            int[] deps;
            foreach (r; ev.phonyDeps[k])
                deps ~= resolveRequired(r, "@" ~ ev.phonyNames[k]);
            succ[numSteps + k] = dedup(deps);
        }

        // 3. default list
        foreach (d; ev.defaults)
            if (resolve(d) < 0)
                throw new KilnError("E_UNKNOWN_TARGET", d);
    }

    private static int[] dedup(int[] deps)
    {
        int[] r;
        bool[int] seen;
        foreach (d; deps)
            if (d !in seen)
            {
                seen[d] = true;
                r ~= d;
            }
        return r;
    }

    private int resolveRequired(string ref_, string by)
    {
        immutable n = resolve(ref_);
        if (n < 0)
            throw new KilnError("E_MISSING_INPUT", ref_ ~ " required by " ~ by);
        return n;
    }

    /// Resolves a target reference to a node id, or -1 if it names nothing.
    int resolve(string ref_)
    {
        if (ref_.length > 0 && ref_[0] == '@')
        {
            if (auto p = ref_[1 .. $] in ev.phonyIndex)
                return numSteps + *p;
            return -1;
        }
        if (auto p = ref_ in outputOwner)
            return *p;
        if (auto p = ref_ in sourceNode)
            return *p;
        if (vfs.exists(ref_))
        {
            immutable id = cast(int) kind.length;
            kind ~= NodeKind.source;
            name ~= ref_;
            succ ~= cast(int[]) null;
            sourceNode[ref_] = id;
            return id;
        }
        return -1;
    }

    /**
     * The requested targets as node ids: the given targets, or the default
     * list when none are given, with duplicates removed.
     *
     * Throws: `E_NO_DEFAULT` or `E_UNKNOWN_TARGET`.
     */
    int[] requested(const(string)[] targets)
    {
        const(string)[] list = targets.length ? targets : ev.defaults;
        if (list.length == 0)
            throw new KilnError("E_NO_DEFAULT");
        int[] r;
        bool[string] seen;
        foreach (t; list)
        {
            if (t in seen)
                continue;
            seen[t] = true;
            immutable n = resolve(t);
            if (n < 0)
                throw new KilnError("E_UNKNOWN_TARGET", t);
            r ~= n;
        }
        return r;
    }

    /**
     * Searches the nodes reachable from `roots` for a cycle with the
     * specified deterministic DFS and returns the reachable set.
     *
     * Throws: `E_CYCLE`.
     */
    bool[] reachable(const(int)[] roots)
    {
        enum ubyte white = 0, grey = 1, black = 2;
        auto colour = new ubyte[kind.length];
        struct Frame
        {
            int node;
            size_t next;
        }

        Frame[] stack;
        foreach (root; roots)
        {
            if (colour[root] != white)
                continue;
            colour[root] = grey;
            stack = [Frame(root, 0)];
            while (stack.length)
            {
                auto top = &stack[$ - 1];
                immutable n = top.node;
                if (top.next < succ[n].length)
                {
                    immutable m = succ[n][top.next];
                    top.next++;
                    if (colour[m] == grey)
                    {
                        size_t j = 0;
                        foreach (k, ref f; stack)
                            if (f.node == m)
                            {
                                j = k;
                                break;
                            }
                        string text;
                        foreach (k; j .. stack.length)
                            text ~= name[stack[k].node] ~ " -> ";
                        text ~= name[m];
                        throw new KilnError("E_CYCLE", text);
                    }
                    if (colour[m] == white)
                    {
                        colour[m] = grey;
                        stack ~= Frame(m, 0);
                    }
                }
                else
                {
                    colour[n] = black;
                    stack.length = stack.length - 1;
                }
            }
        }
        auto r = new bool[kind.length];
        foreach (i; 0 .. kind.length)
            r[i] = colour[i] != white;
        return r;
    }
}

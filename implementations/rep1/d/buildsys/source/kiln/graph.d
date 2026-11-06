/// The dependency graph: reference resolution, validation, cycles, reachability.
module kiln.graph;

import kiln.errors;
import kiln.step;
import kiln.vfs;

/// Dependency graph over step, phony and source nodes.
///
/// Node ids: steps are `0 .. nSteps` (equal to their serial), phony targets
/// follow in declaration order, and source nodes are appended as they are
/// first referenced.
final class Graph
{
    /// Node kinds.
    enum Kind : ubyte
    {
        step,
        phony,
        source
    }

    Kind[] kinds;
    string[] names; /// names used in messages
    int[][] succ; /// de-duplicated ordering dependencies
    int nSteps;
    ubyte[] colour; /// after `findCycle`: 0 = unreached, otherwise reachable

    private Step[] steps;
    private PhonyDecl[] phonies;
    private Vfs vfs;
    private int[string] outOwner; // output path -> step node
    private int[string] phonyNode; // phony name -> node
    private int[string] sourceNode; // source path -> node

    ///
    this(Step[] steps, PhonyDecl[] phonies, Vfs vfs) @safe
    {
        this.steps = steps;
        this.phonies = phonies;
        this.vfs = vfs;
        nSteps = cast(int) steps.length;
        foreach (s; steps)
            addNode(Kind.step, s.primary);
        foreach (p; phonies)
        {
            phonyNode[p.name] = addNode(Kind.phony, "@" ~ p.name);
        }
    }

    private int addNode(Kind k, string name) @safe
    {
        kinds ~= k;
        names ~= name;
        succ ~= null;
        return cast(int) kinds.length - 1;
    }

    /// Number of nodes.
    size_t length() const @safe
    {
        return kinds.length;
    }

    /// Whole-graph check 1: the first output claimed twice is `E_DUP_OUTPUT`.
    void checkDuplicateOutputs() @safe
    {
        foreach (i, s; steps)
            foreach (p; s.fullOutputs)
            {
                if (p in outOwner)
                    throw new KilnError("E_DUP_OUTPUT", p);
                outOwner[p] = cast(int) i;
            }
    }

    /// Resolves a target reference to a node id, or -1 if it resolves to nothing.
    int resolve(string ref_) @safe
    {
        if (ref_.length && ref_[0] == '@')
        {
            if (auto p = ref_[1 .. $] in phonyNode)
                return *p;
            return -1;
        }
        if (auto p = ref_ in outOwner)
            return *p;
        if (auto p = ref_ in sourceNode)
            return *p;
        if (vfs.exists(ref_))
        {
            const id = addNode(Kind.source, ref_);
            sourceNode[ref_] = id;
            return id;
        }
        return -1;
    }

    /// Whole-graph check 2: resolves every `in`, `after` and phony dependency and
    /// builds the successor lists. The first failure is `E_MISSING_INPUT`.
    void resolveReferences() @safe
    {
        auto raw = new int[][](kinds.length);
        int resolveFor(string ref_, string owner)
        {
            const id = resolve(ref_);
            if (id < 0)
                throw new KilnError("E_MISSING_INPUT", ref_ ~ " required by " ~ owner);
            return id;
        }

        foreach (i, s; steps)
        {
            foreach (p; s.ins)
                raw[i] ~= resolveFor(p, s.primary);
            foreach (p; s.afters)
                raw[i] ~= resolveFor(p, s.primary);
        }
        foreach (j, p; phonies)
            foreach (d; p.deps)
                raw[nSteps + j] ~= resolveFor(d, "@" ~ p.name);

        // successor lists with first-occurrence de-duplication
        auto mark = new int[](kinds.length);
        mark[] = -1;
        foreach (n; 0 .. raw.length)
        {
            int[] out_;
            foreach (m; raw[n])
                if (mark[m] != cast(int) n)
                {
                    mark[m] = cast(int) n;
                    out_ ~= m;
                }
            succ[n] = out_;
        }
    }

    /// Depth-first search from `roots` for a cycle. Returns the cycle's node
    /// names (first == last), or null when there is none. When there is none,
    /// `colour[n] != 0` marks the reachable set.
    string[] findCycle(const(int)[] roots) @safe
    {
        colour = new ubyte[](kinds.length); // 0 white, 1 grey, 2 black
        static struct Frame
        {
            int node;
            size_t i;
        }

        Frame[] stack;
        foreach (root; roots)
        {
            if (colour[root] != 0)
                continue;
            colour[root] = 1;
            stack = [Frame(root, 0)];
            while (stack.length)
            {
                auto top = &stack[$ - 1];
                const n = top.node;
                if (top.i < succ[n].length)
                {
                    const m = succ[n][top.i];
                    ++top.i;
                    if (colour[m] == 1)
                    {
                        size_t j = 0;
                        while (stack[j].node != m)
                            ++j;
                        string[] cyc;
                        foreach (k; j .. stack.length)
                            cyc ~= names[stack[k].node];
                        cyc ~= names[m];
                        return cyc;
                    }
                    if (colour[m] == 0)
                    {
                        colour[m] = 1;
                        stack ~= Frame(m, 0);
                    }
                }
                else
                {
                    colour[n] = 2;
                    stack.length = stack.length - 1;
                }
            }
        }
        return null;
    }
}

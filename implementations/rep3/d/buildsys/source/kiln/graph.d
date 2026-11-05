/// The dependency graph: whole-graph validation, target resolution, cycle
/// detection and the reachable set.
module kiln.graph;

import kiln.errors;
import kiln.plan;
import kiln.vfs;

/// Kinds of graph node.
enum NodeKind : ubyte { step, phony, source }

/// A graph node. Steps have node id == serial; phonies follow; then sources.
struct Node
{
    NodeKind kind;
    string name;        /// as used in messages: output path, `@name`, or path
    int[] succ;         /// ordering dependencies, de-duplicated, first-occurrence order
}

/// A validated graph plus the requested targets and reachable set.
final class Graph
{
    Node[] nodes;
    int stepCount;
    int[] requested;
    bool[] reachable;   /// indexed by node id

    private Plan plan;
    private Vfs vfs;
    private int[string] outputOwner;
    private int[string] sourceIndex;

    /// Resolve a target reference to a node id, or -1.
    int resolve(string ref_)
    {
        if (ref_.length > 0 && ref_[0] == '@')
        {
            if (auto p = ref_[1 .. $] in plan.phonyIndex)
                return stepCount + *p;
            return -1;
        }
        if (auto p = ref_ in outputOwner)
            return *p;
        if (auto p = ref_ in sourceIndex)
            return *p;
        if (vfs.exists(ref_))
        {
            int id = cast(int) nodes.length;
            nodes ~= Node(NodeKind.source, ref_, null);
            sourceIndex[ref_] = id;
            return id;
        }
        return -1;
    }
}

private int[] dedup(const(int)[] ids, ref int[] mark, int stamp)
{
    int[] r;
    foreach (id; ids)
    {
        if (mark[id] == stamp)
            continue;
        mark[id] = stamp;
        r ~= id;
    }
    return r;
}

/// Run phases 3-5 of a build: validate the whole graph, resolve the requested
/// targets (`sessionTargets`, or the default list when empty) and check for
/// cycles within the reachable set. Throws the first `KilnError`.
Graph buildGraph(Plan plan, Vfs vfs, string[] sessionTargets)
{
    auto g = new Graph;
    g.plan = plan;
    g.vfs = vfs;
    g.stepCount = cast(int) plan.steps.length;
    foreach (s; plan.steps)
        g.nodes ~= Node(NodeKind.step, s.primary, null);
    foreach (p; plan.phonies)
        g.nodes ~= Node(NodeKind.phony, "@" ~ p.name, null);

    // 1. duplicate outputs
    foreach (s; plan.steps)
        foreach (o; s.fullOutputs())
        {
            if (o in g.outputOwner)
                throw new KilnError("E_DUP_OUTPUT", o);
            g.outputOwner[o] = s.serial;
        }

    // 2. reference resolution (ordering dependencies are collected as we go)
    int[][] ordering = new int[][g.nodes.length];
    foreach (s; plan.steps)
    {
        int[] deps;
        foreach (r; s.ins)
        {
            auto id = g.resolve(r);
            if (id < 0)
                throw new KilnError("E_MISSING_INPUT", r ~ " required by " ~ s.primary);
            deps ~= id;
        }
        foreach (r; s.afters)
        {
            auto id = g.resolve(r);
            if (id < 0)
                throw new KilnError("E_MISSING_INPUT", r ~ " required by " ~ s.primary);
            deps ~= id;
        }
        ordering[s.serial] = deps;
    }
    foreach (pi, p; plan.phonies)
    {
        int[] deps;
        foreach (r; p.deps)
        {
            auto id = g.resolve(r);
            if (id < 0)
                throw new KilnError("E_MISSING_INPUT", r ~ " required by @" ~ p.name);
            deps ~= id;
        }
        ordering[g.stepCount + pi] = deps;
    }

    // 3. default list
    foreach (d; plan.defaults)
        if (g.resolve(d) < 0)
            throw new KilnError("E_UNKNOWN_TARGET", d);

    // successor lists, de-duplicated
    auto mark = new int[g.nodes.length];
    foreach (i; 0 .. mark.length)
        mark[i] = -1;
    foreach (i; 0 .. ordering.length)
        g.nodes[i].succ = dedup(ordering[i], mark, cast(int) i);

    // requested targets
    string[] names;
    bool[string] seen;
    foreach (t; (sessionTargets.length ? sessionTargets : plan.defaults))
        if (t !in seen)
        {
            seen[t] = true;
            names ~= t;
        }
    if (names.length == 0)
        throw new KilnError("E_NO_DEFAULT");
    foreach (t; names)
    {
        auto id = g.resolve(t);
        if (id < 0)
            throw new KilnError("E_UNKNOWN_TARGET", t);
        g.requested ~= id;
    }

    // cycle detection (iterative DFS), which also yields the reachable set
    enum white = 0, grey = 1, black = 2;
    auto colour = new ubyte[g.nodes.length];
    struct Frame { int node; size_t next; }
    foreach (root; g.requested)
    {
        if (colour[root] != white)
            continue;
        colour[root] = grey;
        Frame[] stack = [Frame(root, 0)];
        while (stack.length)
        {
            auto top = &stack[$ - 1];
            auto succ = g.nodes[top.node].succ;
            if (top.next < succ.length)
            {
                immutable m = succ[top.next++];
                if (colour[m] == grey)
                {
                    size_t j = 0;
                    while (stack[j].node != m)
                        ++j;
                    string msg;
                    foreach (k; j .. stack.length)
                        msg ~= g.nodes[stack[k].node].name ~ " -> ";
                    msg ~= g.nodes[m].name;
                    throw new KilnError("E_CYCLE", msg);
                }
                if (colour[m] == white)
                {
                    colour[m] = grey;
                    stack ~= Frame(m, 0);
                }
            }
            else
            {
                colour[top.node] = black;
                stack.length = stack.length - 1;
            }
        }
    }
    g.reachable = new bool[g.nodes.length];
    foreach (i; 0 .. colour.length)
        g.reachable[i] = colour[i] != white;
    return g;
}

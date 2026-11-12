/**
 * The dependency graph of one build: steps, phony targets and source files,
 * with whole-graph validation, target resolution and cycle detection.
 */
module kiln.graph;

import kiln.errors;
import kiln.model;
import kiln.workspace : Workspace;

/// What a graph node stands for.
enum NodeKind : ubyte
{
    step,
    phony,
    source,
}

/// A graph node. Step `i` has node id `i`; phony `j` has id `steps + j`; source nodes follow.
struct Node
{
    NodeKind kind;
    /// Step or phony index (unused for sources).
    size_t index;
    /// Name used in messages: primary output, `@phony`, or the source path.
    string name;
    /// Ordering dependencies with duplicates removed, first occurrence kept.
    int[] successors;
}

/// The graph for one build.
final class Graph
{
    /// All nodes.
    Node[] nodes;
    private BuildPlan plan;
    private Workspace ws;
    private size_t[string] outputOwner;
    private int[string] sourceIds;

    /**
     * Builds the graph and performs the whole-graph validation:
     * duplicate outputs, then reference resolution, then the default list.
     * Throws `KilnError` (`E_DUP_OUTPUT`, `E_MISSING_INPUT`, `E_UNKNOWN_TARGET`).
     */
    this(BuildPlan plan, Workspace ws) @safe
    {
        this.plan = plan;
        this.ws = ws;
        foreach (i, s; plan.steps)
            nodes ~= Node(NodeKind.step, i, s.primary);
        foreach (j, p; plan.phonies)
            nodes ~= Node(NodeKind.phony, j, "@" ~ p.name);

        foreach (i, s; plan.steps)
            foreach (o; s.fullOuts)
            {
                if (o in outputOwner)
                    fail("E_DUP_OUTPUT", o);
                outputOwner[o] = i;
            }

        foreach (i, s; plan.steps)
        {
            int[] succ;
            foreach (r; s.ins)
                succ ~= resolveRequired(r, s.primary);
            foreach (r; s.afters)
                succ ~= resolveRequired(r, s.primary);
            nodes[i].successors = dedup(succ);
        }
        foreach (j, p; plan.phonies)
        {
            int[] succ;
            foreach (r; p.deps)
                succ ~= resolveRequired(r, "@" ~ p.name);
            nodes[plan.steps.length + j].successors = dedup(succ);
        }
        foreach (r; plan.defaults)
            if (resolve(r) < 0)
                fail("E_UNKNOWN_TARGET", r);
    }

    private int resolveRequired(string ref_, string requiredBy) @safe
    {
        immutable n = resolve(ref_);
        if (n < 0)
            fail("E_MISSING_INPUT", ref_ ~ " required by " ~ requiredBy);
        return n;
    }

    /// Resolves a target reference to a node id, or -1 if it names nothing.
    int resolve(string target) @safe
    {
        if (target.length > 0 && target[0] == '@')
        {
            if (auto p = target[1 .. $] in plan.phonyIndex)
                return cast(int)(plan.steps.length + *p);
            return -1;
        }
        if (auto p = target in outputOwner)
            return cast(int) *p;
        if (auto p = target in sourceIds)
            return *p;
        if (ws.exists(target))
        {
            immutable id = cast(int) nodes.length;
            nodes ~= Node(NodeKind.source, 0, target);
            sourceIds[target] = id;
            return id;
        }
        return -1;
    }

    /**
     * Resolves the requested targets (`E_UNKNOWN_TARGET` on failure), with
     * duplicates removed keeping the first occurrence.
     */
    int[] resolveTargets(const(string)[] targets) @safe
    {
        int[] roots;
        foreach (t; targets)
        {
            immutable n = resolve(t);
            if (n < 0)
                fail("E_UNKNOWN_TARGET", t);
            roots ~= n;
        }
        return dedup(roots);
    }

    /**
     * Searches for a cycle among the nodes reachable from `roots` with the
     * spec's exact depth-first search. Throws `E_CYCLE`; otherwise returns the
     * reachable set (grey or black nodes) as node ids.
     */
    int[] reachable(const(int)[] roots) @safe
    {
        enum : ubyte
        {
            white,
            grey,
            black
        }
        auto colour = new ubyte[nodes.length];
        int[] visited;
        struct Frame
        {
            int node;
            size_t next;
        }

        foreach (root; roots)
        {
            if (colour[root] != white)
                continue;
            colour[root] = grey;
            visited ~= root;
            Frame[] stack = [Frame(root, 0)];
            while (stack.length)
            {
                auto top = &stack[$ - 1];
                auto succ = nodes[top.node].successors;
                if (top.next < succ.length)
                {
                    immutable m = succ[top.next];
                    top.next++;
                    if (colour[m] == grey)
                    {
                        size_t j = 0;
                        while (stack[j].node != m)
                            j++;
                        string[] names;
                        foreach (f; stack[j .. $])
                            names ~= nodes[f.node].name;
                        names ~= nodes[m].name;
                        string text;
                        foreach (k, n; names)
                            text ~= (k ? " -> " : "") ~ n;
                        fail("E_CYCLE", text);
                    }
                    if (colour[m] == white)
                    {
                        colour[m] = grey;
                        visited ~= m;
                        stack ~= Frame(m, 0);
                    }
                }
                else
                {
                    colour[top.node] = black;
                    stack = stack[0 .. $ - 1];
                }
            }
        }
        return visited;
    }
}

/// Removes duplicates, keeping the first occurrence of each.
private int[] dedup(int[] xs) @safe pure
{
    if (xs.length < 2)
        return xs;
    bool[int] seen;
    int[] r;
    r.reserve(xs.length);
    foreach (x; xs)
    {
        if (x in seen)
            continue;
        seen[x] = true;
        r ~= x;
    }
    return r;
}

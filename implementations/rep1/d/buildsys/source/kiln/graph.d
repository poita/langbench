/**
 * The dependency graph: nodes for steps, phony targets and source files,
 * whole-graph validation, target resolution and deterministic cycle detection.
 */
module kiln.graph;

import kiln.errors;
import kiln.eval : Evaluation, Phony;
import kiln.step;
import kiln.text : startsWithBytes;
import kiln.vfs;

/// Node kinds.
enum NodeKind : ubyte { step, phony, source }

/// A graph node.
struct Node
{
    ///
    NodeKind kind;
    /// Name used in messages: primary output, `@name`, or the source path.
    string name;
    /// Distinct ordering dependencies, first occurrence kept.
    int[] successors;
}

/// The graph of one build.
final class Graph
{
    /// Nodes: steps first (node id == serial), then phonies, then sources.
    Node[] nodes;
    ///
    Step[] steps;
    private Phony[] phonies;
    private int[string] outputOwner; // output path -> step node
    private int[string] phonyNode;   // phony name -> node
    private int[string] sourceNode;  // path -> node
    private Vfs fs;

    /// Creates the nodes for `ev` and checks for duplicate outputs.
    ///
    /// Throws: `KilnError` (`E_DUP_OUTPUT`).
    this(Evaluation ev, Vfs fs)
    {
        this.fs = fs;
        steps = ev.steps;
        phonies = ev.phonies;
        foreach (st; steps)
            nodes ~= Node(NodeKind.step, st.primary);
        foreach (ph; phonies)
        {
            phonyNode[ph.name] = cast(int) nodes.length;
            nodes ~= Node(NodeKind.phony, "@" ~ ph.name);
        }
        foreach (st; steps)
        {
            foreach (p; st.fullOuts)
            {
                if (p in outputOwner)
                    throw new KilnError("E_DUP_OUTPUT", p);
                outputOwner[p] = st.serial;
            }
        }
    }

    /// Resolves a target reference to a node id, or -1.
    int resolve(string ref_)
    {
        if (startsWithBytes(ref_, "@"))
        {
            auto p = ref_[1 .. $] in phonyNode;
            return p ? *p : -1;
        }
        if (auto p = ref_ in outputOwner)
            return *p;
        if (auto p = ref_ in sourceNode)
            return *p;
        if (fs.exists(ref_))
        {
            const id = cast(int) nodes.length;
            nodes ~= Node(NodeKind.source, ref_);
            sourceNode[ref_] = id;
            return id;
        }
        return -1;
    }

    /// Reference resolution and default-list validation (steps 2 and 3 of whole-graph validation).
    ///
    /// Throws: `KilnError` (`E_MISSING_INPUT`, `E_UNKNOWN_TARGET`).
    void validate(const(string)[] defaults)
    {
        foreach (st; steps)
        {
            int[] succ;
            foreach (list; [st.ins, st.afters])
                foreach (r; list)
                {
                    const id = resolve(r);
                    if (id < 0)
                        throw new KilnError("E_MISSING_INPUT", r ~ " required by " ~ st.primary);
                    succ ~= id;
                }
            nodes[st.serial].successors = dedupe(succ);
        }
        foreach (i, ph; phonies)
        {
            int[] succ;
            foreach (r; ph.deps)
            {
                const id = resolve(r);
                if (id < 0)
                    throw new KilnError("E_MISSING_INPUT", r ~ " required by @" ~ ph.name);
                succ ~= id;
            }
            nodes[phonyNode[ph.name]].successors = dedupe(succ);
        }
        foreach (r; defaults)
            if (resolve(r) < 0)
                throw new KilnError("E_UNKNOWN_TARGET", r);
    }

    /**
     * Resolves the requested targets and searches the reachable set for cycles.
     *
     * Returns: the per-node reachability flags (grey or black nodes of the search).
     * Throws: `KilnError` (`E_NO_DEFAULT`, `E_UNKNOWN_TARGET`, `E_CYCLE`).
     */
    bool[] reachable(const(string)[] requested, const(string)[] defaults, out int[] roots)
    {
        const(string)[] want = requested.length ? requested : defaults;
        if (want.length == 0)
            throw new KilnError("E_NO_DEFAULT");
        bool[string] seen;
        foreach (t; want)
        {
            if (t in seen)
                continue;
            seen[t] = true;
            const id = resolve(t);
            if (id < 0)
                throw new KilnError("E_UNKNOWN_TARGET", t);
            roots ~= id;
        }
        return findCycle(roots);
    }

    private bool[] findCycle(const(int)[] roots)
    {
        enum White = 0, Grey = 1, Black = 2;
        auto colour = new ubyte[nodes.length];
        struct Frame { int node; size_t next; }
        Frame[] stack;
        foreach (root; roots)
        {
            if (colour[root] != White)
                continue;
            colour[root] = Grey;
            stack = [Frame(root, 0)];
            while (stack.length)
            {
                auto top = &stack[$ - 1];
                const succ = nodes[top.node].successors;
                if (top.next < succ.length)
                {
                    const m = succ[top.next];
                    ++top.next;
                    if (colour[m] == Grey)
                    {
                        size_t j = 0;
                        while (stack[j].node != m)
                            ++j;
                        string[] names;
                        foreach (k; j .. stack.length)
                            names ~= nodes[stack[k].node].name;
                        names ~= nodes[m].name;
                        string detail;
                        foreach (i, n; names)
                            detail ~= (i ? " -> " : "") ~ n;
                        throw new KilnError("E_CYCLE", detail);
                    }
                    if (colour[m] == White)
                    {
                        colour[m] = Grey;
                        stack ~= Frame(m, 0);
                    }
                }
                else
                {
                    colour[top.node] = Black;
                    stack = stack[0 .. $ - 1];
                }
            }
        }
        auto reach = new bool[nodes.length];
        foreach (i, c; colour)
            reach[i] = c != White;
        return reach;
    }
}

private int[] dedupe(const(int)[] ids) @safe pure nothrow
{
    int[] r;
    bool[int] seen;
    foreach (i; ids)
    {
        if (i in seen)
            continue;
        seen[i] = true;
        r ~= i;
    }
    return r;
}

version (unittest)
{
    import kiln.eval : evaluateWorkspace;

    private string graphErr(string main, string[] requested = [], string[string] files = null)
    {
        auto fs = new Vfs;
        foreach (k, v; files)
            fs.write(k, v);
        fs.write("main.kiln", main);
        try
        {
            auto ev = evaluateWorkspace(fs);
            auto g = new Graph(ev, fs);
            g.validate(ev.defaults);
            int[] roots;
            g.reachable(requested, ev.defaults, roots);
            return "ok";
        }
        catch (KilnError e)
            return e.msg;
    }
}

unittest
{
    enum two = "step {\n out \"out/x.txt\"\n in \"out/y.txt\"\n cmd copy()\n}\n"
        ~ "step {\n out \"out/y.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\n";
    assert(graphErr(two ~ "default \"out/x.txt\"\n") == "E_CYCLE out/x.txt -> out/y.txt -> out/x.txt");
    assert(graphErr("step {\n out \"out/x.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\ndefault \"out/x.txt\"\n")
            == "E_CYCLE out/x.txt -> out/x.txt");
    // An unreachable cycle is not reported.
    assert(graphErr(two ~ "step {\n out \"out/z\"\n cmd write(\"\")\n}\ndefault \"out/z\"\n") == "ok");
    assert(graphErr("") == "E_NO_DEFAULT");
    assert(graphErr("default \"nope\"\n") == "E_UNKNOWN_TARGET nope");
    assert(graphErr("phony a = [\"@b\"]\ndefault \"@a\"\n") == "E_MISSING_INPUT @b required by @a");
    assert(graphErr("step {\n out \"out/a\"\n cmd write(\"\")\n}\nstep {\n out \"out/b\"\n depfile \"out/a\"\n cmd preprocess()\n in \"main.kiln\"\n}\n")
            == "E_DUP_OUTPUT out/a");
}

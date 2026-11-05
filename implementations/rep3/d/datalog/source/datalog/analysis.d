/**
 * Static checks: rule safety and stratification.
 *
 * Safety is checked per rule. Stratification builds the predicate dependency
 * graph, computes its strongly connected components with Tarjan's algorithm and
 * rejects programs with a negative edge inside a component.
 */
module datalog.analysis;

import datalog.ast;

/**
 * A rule is safe when every variable in its head, in a negated atom or in a
 * comparison also occurs in a positive body atom.
 */
bool isSafe(const ref Rule rule) pure nothrow @safe
{
    auto positive = new bool[rule.numVars];
    foreach (ref l; rule.body)
        if (l.kind == LiteralKind.positive)
            foreach (t; l.atom.args)
                if (t.isVar)
                    positive[t.id] = true;

    bool ok(Term t) { return !t.isVar || positive[t.id]; }

    foreach (t; rule.head.args)
        if (!ok(t))
            return false;
    foreach (ref l; rule.body)
    {
        final switch (l.kind)
        {
        case LiteralKind.positive:
            break;
        case LiteralKind.negative:
            foreach (t; l.atom.args)
                if (!ok(t))
                    return false;
            break;
        case LiteralKind.comparison:
            if (!ok(l.lhs) || !ok(l.rhs))
                return false;
            break;
        }
    }
    return true;
}

/// True if every rule of the program is safe.
bool isSafe(const ref Program program) pure nothrow @safe
{
    foreach (ref r; program.rules)
        if (!isSafe(r))
            return false;
    return true;
}

/// Evaluation order of the predicates.
struct Stratification
{
    /// Component index of every predicate.
    uint[] componentOf;
    /// Predicates of each component; components are in evaluation order
    /// (a component only depends on earlier ones and on itself).
    uint[][] components;
    /// True if the component's predicates depend on each other (or themselves).
    bool[] recursive;
}

/**
 * Computes the stratification of a program.
 *
 * Returns: `false` if some cycle of the dependency graph contains a negative
 * edge (the program is not stratifiable); otherwise `true` with `result` filled in.
 */
bool stratify(const ref Program program, out Stratification result) pure @safe
{
    const n = program.predicates.length;
    // Edges head -> body predicate ("depends on"); Tarjan then emits components
    // dependencies-first, which is the evaluation order.
    uint[][] deps = new uint[][n];
    struct NegEdge { uint from, to; }
    NegEdge[] negEdges;
    bool[] selfLoop = new bool[n];
    foreach (ref r; program.rules)
    {
        foreach (ref l; r.body)
        {
            if (l.kind == LiteralKind.comparison)
                continue;
            const h = r.head.predicate, q = l.atom.predicate;
            deps[h] ~= q;
            if (h == q) selfLoop[h] = true;
            if (l.kind == LiteralKind.negative)
                negEdges ~= NegEdge(h, q);
        }
    }

    enum uint unvisited = uint.max;
    auto index = new uint[n];
    auto low = new uint[n];
    auto onStack = new bool[n];
    index[] = unvisited;
    result.componentOf = new uint[n];
    uint counter;
    uint[] stack;

    void visit(uint v)
    {
        index[v] = low[v] = counter++;
        stack ~= v;
        onStack[v] = true;
        foreach (w; deps[v])
        {
            if (index[w] == unvisited)
            {
                visit(w);
                if (low[w] < low[v]) low[v] = low[w];
            }
            else if (onStack[w] && index[w] < low[v])
                low[v] = index[w];
        }
        if (low[v] == index[v])
        {
            uint[] comp;
            const id = cast(uint) result.components.length;
            uint w;
            do
            {
                w = stack[$ - 1];
                stack.length--;
                onStack[w] = false;
                result.componentOf[w] = id;
                comp ~= w;
            } while (w != v);
            result.components ~= comp;
        }
    }

    foreach (v; 0 .. cast(uint) n)
        if (index[v] == unvisited)
            visit(v);

    foreach (e; negEdges)
        if (result.componentOf[e.from] == result.componentOf[e.to])
            return false;

    result.recursive = new bool[result.components.length];
    foreach (c, comp; result.components)
        result.recursive[c] = comp.length > 1 || selfLoop[comp[0]];
    return true;
}

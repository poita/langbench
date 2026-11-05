/// Static checks: rule safety and stratification, plus the evaluation order.
module datalog.analysis;

import datalog.ast;

/// Outcome of static analysis.
enum Status : ubyte
{
    ok,
    /// Some rule has a variable not bound by a positive body atom.
    unsafeRule,
    /// A cycle of the predicate dependency graph contains a negative edge.
    notStratifiable
}

/// A strongly connected component of the predicate dependency graph.
struct Component
{
    /// Predicates in the component.
    PredId[] preds;
    /// True if some rule of the component depends on a predicate of the component.
    bool recursive;
    /// Indices into `Program.rules` of the non-fact rules whose head is in the component.
    size_t[] rules;
}

/// Result of `analyze`.
struct Analysis
{
    Status status;
    /// Components in evaluation (topological) order: a component only depends on
    /// earlier ones. Valid only if `status == Status.ok`.
    Component[] components;
}

/// A rule is safe when every variable in its head, in a negated atom or in a
/// comparison occurs in some positive body atom.
bool isSafe(in Rule rule) @safe pure
{
    auto bound = new bool[rule.numVars];
    foreach (ref l; rule.body)
        if (l.kind == LiteralKind.positive)
            foreach (t; l.atom.args)
                if (t.isVar) bound[t.id] = true;

    bool ok(Term t) { return !t.isVar || bound[t.id]; }
    foreach (t; rule.head.args)
        if (!ok(t)) return false;
    foreach (ref l; rule.body)
    {
        final switch (l.kind)
        {
        case LiteralKind.positive:
            break;
        case LiteralKind.negative:
            foreach (t; l.atom.args)
                if (!ok(t)) return false;
            break;
        case LiteralKind.comparison:
            if (!ok(l.lhs) || !ok(l.rhs)) return false;
            break;
        }
    }
    return true;
}

/// Check safety and stratifiability of `prog` and compute its evaluation order.
Analysis analyze(in Program prog) @safe pure
{
    Analysis result;
    foreach (ref r; prog.rules)
        if (!isSafe(r))
        {
            result.status = Status.unsafeRule;
            return result;
        }

    immutable n = prog.predicates.length;
    // deps[p] = predicates p's rules depend on (edge p -> q means "p needs q").
    struct Edge { PredId to; bool negative; }
    auto deps = new Edge[][n];
    foreach (ref r; prog.rules)
        foreach (ref l; r.body)
            if (l.kind != LiteralKind.comparison)
                deps[r.head.pred] ~= Edge(l.atom.pred, l.kind == LiteralKind.negative);

    // Tarjan's algorithm. With edges pointing from dependents to dependencies,
    // components are emitted dependencies-first, which is the evaluation order.
    auto index = new int[n];
    auto low = new int[n];
    auto onStack = new bool[n];
    auto compOf = new int[n];
    index[] = -1;
    PredId[] stack;
    int counter = 0;
    PredId[][] comps;

    void visit(PredId v)
    {
        index[v] = low[v] = counter++;
        stack ~= v;
        onStack[v] = true;
        foreach (e; deps[v])
        {
            if (index[e.to] < 0)
            {
                visit(e.to);
                if (low[e.to] < low[v]) low[v] = low[e.to];
            }
            else if (onStack[e.to] && index[e.to] < low[v])
                low[v] = index[e.to];
        }
        if (low[v] == index[v])
        {
            PredId[] comp;
            PredId w;
            do
            {
                w = stack[$ - 1];
                stack.length = stack.length - 1;
                onStack[w] = false;
                compOf[w] = cast(int) comps.length;
                comp ~= w;
            } while (w != v);
            comps ~= comp;
        }
    }
    foreach (v; 0 .. n)
        if (index[v] < 0) visit(cast(PredId) v);

    foreach (v; 0 .. n)
        foreach (e; deps[v])
            if (e.negative && compOf[e.to] == compOf[v])
            {
                result.status = Status.notStratifiable;
                return result;
            }

    result.components = new Component[comps.length];
    foreach (i, c; comps)
        result.components[i].preds = c;
    foreach (ri, ref r; prog.rules)
    {
        if (r.isFact) continue;
        immutable c = compOf[r.head.pred];
        result.components[c].rules ~= ri;
        foreach (ref l; r.body)
            if (l.kind == LiteralKind.positive && compOf[l.atom.pred] == c)
                result.components[c].recursive = true;
    }
    result.status = Status.ok;
    return result;
}

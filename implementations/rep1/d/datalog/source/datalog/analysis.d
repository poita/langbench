/// Static checks: rule safety and stratification of the predicate dependency graph.
module datalog.analysis;

import std.conv : to;

import datalog.ast;
import datalog.errors;

/// Throw `UnsafeRuleException` unless every rule is safe.
///
/// A rule is safe when each variable in its head, in a negated atom or in a
/// comparison also occurs in a positive body atom. Facts must be ground.
void checkSafety(const Program program) @safe
{
    foreach (ruleIndex, ref rule; program.rules)
    {
        auto bound = new bool[rule.numVars];
        foreach (ref lit; rule.body)
            if (lit.kind == LiteralKind.positive)
                foreach (t; lit.atom.args)
                    if (t.isVariable)
                        bound[t.id] = true;

        void require(Term t, string where)
        {
            if (t.isVariable && !bound[t.id])
                throw new UnsafeRuleException("unsafe rule for " ~ program.predicates[rule.head.pred].name
                        ~ " (clause " ~ (ruleIndex + 1).to!string ~ "): variable in " ~ where
                        ~ " does not occur in a positive body atom");
        }

        foreach (t; rule.head.args)
            require(t, "the head");
        foreach (ref lit; rule.body)
        {
            final switch (lit.kind)
            {
            case LiteralKind.positive:
                break;
            case LiteralKind.negative:
                foreach (t; lit.atom.args)
                    require(t, "a negated atom");
                break;
            case LiteralKind.comparison:
                require(lit.lhs, "a comparison");
                require(lit.rhs, "a comparison");
                break;
            }
        }
    }
}

/// Strongly connected components of the predicate dependency graph.
struct Stratification
{
    /// `componentOf[pred]` is the index into `components`.
    uint[] componentOf;
    /// Components in evaluation order: every component comes after the ones it depends on.
    uint[][] components;
}

/// Compute the components of the dependency graph (edge `q -> p` for every rule
/// with head `p` and body atom `q`) in topological order.
///
/// Throws `StratificationException` if a negative edge lies inside a component.
Stratification stratify(const Program program) @safe
{
    immutable n = program.predicates.length;
    auto adj = new uint[][n]; // adj[q] = heads depending on q

    foreach (ref rule; program.rules)
        foreach (ref lit; rule.body)
            if (lit.kind != LiteralKind.comparison)
                adj[lit.atom.pred] ~= rule.head.pred;

    // Tarjan's algorithm.
    auto index = new int[n];
    auto low = new int[n];
    auto onStack = new bool[n];
    index[] = -1;
    uint[] stack;
    int counter = 0;
    uint[][] found; // reverse topological order
    auto componentOf = new uint[n];

    void visit(uint v)
    {
        index[v] = low[v] = counter++;
        stack ~= v;
        onStack[v] = true;
        foreach (w; adj[v])
        {
            if (index[w] < 0)
            {
                visit(w);
                if (low[w] < low[v])
                    low[v] = low[w];
            }
            else if (onStack[w] && index[w] < low[v])
                low[v] = index[w];
        }
        if (low[v] == index[v])
        {
            uint[] comp;
            uint w;
            do
            {
                w = stack[$ - 1];
                stack.length = stack.length - 1;
                onStack[w] = false;
                comp ~= w;
            }
            while (w != v);
            found ~= comp;
        }
    }

    foreach (v; 0 .. cast(uint) n)
        if (index[v] < 0)
            visit(v);

    Stratification result;
    foreach_reverse (comp; found)
        result.components ~= comp;
    foreach (ci, comp; result.components)
        foreach (p; comp)
            componentOf[p] = cast(uint) ci;
    result.componentOf = componentOf;

    foreach (ref rule; program.rules)
        foreach (ref lit; rule.body)
            if (lit.kind == LiteralKind.negative
                && componentOf[lit.atom.pred] == componentOf[rule.head.pred])
                throw new StratificationException("not stratifiable: " ~ program.predicates[rule.head.pred].name
                        ~ " depends negatively on " ~ program.predicates[lit.atom.pred].name
                        ~ " within a recursive cycle");
    return result;
}

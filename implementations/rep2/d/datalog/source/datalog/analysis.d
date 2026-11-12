/// Static checks: rule safety and stratification.
module datalog.analysis;

import datalog.ast;
import datalog.errors;
import std.conv : to;

/// Checks that every rule is safe.
///
/// A rule is safe when each variable occurring in its head, in a negated atom
/// or in a comparison also occurs in a positive body atom of the same rule.
/// (A fact is safe only if its head is ground; an anonymous variable outside a
/// positive atom is therefore always unsafe.)
///
/// Throws: `UnsafeRuleException` on the first unsafe rule.
void checkSafety(const Program program) @safe
{
    foreach (i, ref rule; program.rules)
    {
        auto bound = new bool[rule.numVars];
        foreach (ref lit; rule.body)
            if (lit.kind == LiteralKind.positive)
                foreach (t; lit.atom.args)
                    if (t.isVariable)
                        bound[t.id] = true;

        void need(Term t)
        {
            if (t.isVariable && !bound[t.id])
                throw new UnsafeRuleException("rule " ~ (i + 1).to!string
                        ~ " is unsafe: a variable is not bound by a positive body atom");
        }

        foreach (t; rule.head.args)
            need(t);
        foreach (ref lit; rule.body)
            final switch (lit.kind)
            {
            case LiteralKind.positive:
                break;
            case LiteralKind.negative:
                foreach (t; lit.atom.args)
                    need(t);
                break;
            case LiteralKind.comparison:
                need(lit.lhs);
                need(lit.rhs);
                break;
            }
    }
}

/// The strongly connected components of the predicate dependency graph.
struct Stratification
{
    /// Components in evaluation order: a component only depends on earlier ones
    /// (and on itself). Each lists its predicates.
    PredId[][] components;
    /// Index into `components` for every predicate.
    uint[] componentOf;
}

/// Computes the evaluation order of the predicates with Tarjan's algorithm
/// and rejects negation inside a recursive cycle.
///
/// Throws: `StratificationException` if a negative edge lies on a cycle.
Stratification stratify(const Program program) @safe
{
    immutable n = program.predicates.length;
    struct Edge
    {
        PredId to;
        bool negative;
    }

    // Edge head -> body predicate: "head depends on body".
    auto adj = new Edge[][n];
    foreach (ref rule; program.rules)
        foreach (ref lit; rule.body)
            if (lit.kind != LiteralKind.comparison)
                adj[rule.head.pred] ~= Edge(lit.atom.pred, lit.kind == LiteralKind.negative);

    auto index = new int[n];
    auto low = new int[n];
    auto onStack = new bool[n];
    index[] = -1;
    int counter = 0;
    PredId[] stack;
    Stratification result;
    result.componentOf = new uint[n];

    // Tarjan emits a component only after everything it depends on, which is
    // exactly the evaluation order.
    void visit(PredId v)
    {
        index[v] = low[v] = counter++;
        stack ~= v;
        onStack[v] = true;
        foreach (e; adj[v])
        {
            if (index[e.to] < 0)
            {
                visit(e.to);
                if (low[e.to] < low[v])
                    low[v] = low[e.to];
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
                stack = stack[0 .. $ - 1];
                onStack[w] = false;
                result.componentOf[w] = cast(uint) result.components.length;
                comp ~= w;
            }
            while (w != v);
            result.components ~= comp;
        }
    }

    foreach (v; 0 .. cast(PredId) n)
        if (index[v] < 0)
            visit(v);

    foreach (v; 0 .. n)
        foreach (e; adj[v])
            if (e.negative && result.componentOf[v] == result.componentOf[e.to])
                throw new StratificationException("predicate " ~ program.predicates[v].name
                        ~ " depends negatively on itself through a cycle");
    return result;
}

version (unittest)
{
    import datalog.parser : parseProgram;
    import std.exception : assertThrown, assertNotThrown;
}

@("analysis: safe and unsafe rules")
@safe unittest
{
    assertNotThrown(checkSafety(parseProgram("p(X) :- q(X, _), not r(X), X < 3. s(a).")));
    assertNotThrown(checkSafety(parseProgram("p(a) :- 1 < 2.")));
    foreach (src; ["p(X).", "p(_).", "p(X) :- q(Y).", "p(X) :- q(X), not r(Y).",
            "p(X) :- q(X), not r(_).", "p(X) :- q(X), Y = 5.", "p(Y) :- q(X), X = Y.",
            "p(X) :- q(X), X < _."])
        assertThrown!UnsafeRuleException(checkSafety(parseProgram(src)), src);
}

@("analysis: stratification order")
@safe unittest
{
    auto p = parseProgram("a(X) :- b(X). b(X) :- c(X), not d(X). d(1). c(1).");
    auto s = stratify(p);
    // every dependency lies in an earlier (or the same) component
    foreach (ref r; p.rules)
        foreach (ref l; r.body)
            assert(s.componentOf[l.atom.pred] <= s.componentOf[r.head.pred]);
    assert(s.componentOf[p.rules[1].body[1].atom.pred] < s.componentOf[p.rules[1].head.pred]);
}

@("analysis: negative cycles are rejected, positive ones are fine")
@safe unittest
{
    assertThrown!StratificationException(stratify(parseProgram("w(X) :- e(X, Y), not w(Y).")));
    assertThrown!StratificationException(stratify(parseProgram("p(X) :- q(X). q(X) :- r(X), not p(X).")));
    auto s = stratify(parseProgram("p(X) :- q(X). q(X) :- p(X). r(X) :- e(X), not p(X)."));
    assert(s.components.length == 3); // {p, q}, {e}, {r}
}

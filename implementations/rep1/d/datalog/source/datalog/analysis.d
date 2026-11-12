/// Static checks: rule safety and stratification.
module datalog.analysis;

import std.format : format;

import datalog.ast;
import datalog.errors;

/// Throws `UnsafeRuleException` unless every rule is safe: each variable of
/// the head, of a negated atom or of a comparison must also occur in a
/// positive body atom of the same rule. (A fact must have no variables.)
void checkSafety(const Program program) @safe pure
{
    foreach (ruleNo, ref rule; program.rules)
    {
        auto bound = new bool[rule.numVars];
        foreach (ref lit; rule.body)
            if (lit.kind == LiteralKind.positive)
                foreach (t; lit.atom.args)
                    if (t.kind == TermKind.variable)
                        bound[t.id] = true;

        void need(Term t, string where)
        {
            if (t.kind == TermKind.variable && !bound[t.id])
                throw new UnsafeRuleException(
                    format("unsafe rule %s: a variable in %s is not bound by a positive atom",
                        ruleNo + 1, where));
        }

        foreach (t; rule.head.args)
            need(t, "the head");
        foreach (ref lit; rule.body)
        {
            final switch (lit.kind)
            {
            case LiteralKind.positive:
                break;
            case LiteralKind.negated:
                foreach (t; lit.atom.args)
                    need(t, "a negated atom");
                break;
            case LiteralKind.comparison:
                need(lit.lhs, "a comparison");
                need(lit.rhs, "a comparison");
                break;
            }
        }
    }
}

/// A group of mutually dependent predicates, evaluated together.
struct Stratum
{
    /// Predicate ids belonging to this stratum.
    uint[] predicates;
    /// Indices into `Program.rules` of the rules (not facts) whose head is in the stratum.
    size_t[] rules;
    /// True when some rule has a positive body atom on a predicate of the stratum.
    bool recursive;
}

/// Splits the predicates into the strongly connected components of the
/// dependency graph and returns them in an evaluation order (every stratum
/// comes after all strata it depends on). Facts are not included in
/// `Stratum.rules`. Throws `StratificationException` if some component
/// contains a negative edge.
Stratum[] stratify(const Program program) @safe pure
{
    immutable n = program.predicates.length;
    struct Edge
    {
        uint to;
        bool negative;
    }

    // Edge head -> body predicate, so that Tarjan emits dependencies first.
    auto adj = new Edge[][n];
    foreach (ref rule; program.rules)
        foreach (ref lit; rule.body)
            if (lit.kind != LiteralKind.comparison)
                adj[rule.head.predicate] ~= Edge(lit.atom.predicate, lit.kind == LiteralKind.negated);

    auto index = new int[n];
    auto low = new int[n];
    auto onStack = new bool[n];
    auto component = new int[n];
    index[] = -1;
    uint[] stack;
    uint[][] components;
    int counter = 0;

    void connect(uint v)
    {
        index[v] = low[v] = counter++;
        stack ~= v;
        onStack[v] = true;
        foreach (e; adj[v])
        {
            if (index[e.to] < 0)
            {
                connect(e.to);
                if (low[e.to] < low[v])
                    low[v] = low[e.to];
            }
            else if (onStack[e.to] && index[e.to] < low[v])
                low[v] = index[e.to];
        }
        if (low[v] == index[v])
        {
            uint[] comp;
            uint w;
            do
            {
                w = stack[$ - 1];
                stack = stack[0 .. $ - 1];
                onStack[w] = false;
                component[w] = cast(int) components.length;
                comp ~= w;
            }
            while (w != v);
            components ~= comp;
        }
    }

    foreach (v; 0 .. n)
        if (index[v] < 0)
            connect(cast(uint) v);

    auto strata = new Stratum[components.length];
    foreach (i, comp; components)
        strata[i].predicates = comp;

    foreach (ruleNo, ref rule; program.rules)
    {
        immutable c = component[rule.head.predicate];
        foreach (ref lit; rule.body)
        {
            if (lit.kind == LiteralKind.comparison || component[lit.atom.predicate] != c)
                continue;
            if (lit.kind == LiteralKind.negated)
                throw new StratificationException(
                    "not stratifiable: " ~ program.predicates[rule.head.predicate].name
                    ~ " depends negatively on " ~ program.predicates[lit.atom.predicate].name
                    ~ " within a cycle");
            strata[c].recursive = true;
        }
        if (rule.body.length)
            strata[c].rules ~= ruleNo;
    }
    return strata;
}

version (unittest)
{
    import datalog.parser : parseProgram;
}

@safe pure unittest
{
    import std.exception : assertNotThrown, assertThrown;

    assertNotThrown(checkSafety(parseProgram("p(X) :- q(X), not r(X), X < 3. p(1). p(_x) :- q(_x).")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(X).")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(_).")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(X) :- q(Y).")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(X) :- q(X), not r(Y).")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(X) :- q(X), not r(_).")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(Y) :- q(X), X = Y.")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(X) :- q(X), Y = 5.")));
    assertThrown!UnsafeRuleException(checkSafety(parseProgram("p(X) :- X < 3.")));
    assertNotThrown(checkSafety(parseProgram("p(a) :- not q(b), 1 < 2.")));
}

@safe pure unittest
{
    import std.exception : assertThrown;

    auto p = parseProgram("e(1,2). path(X,Y) :- e(X,Y). path(X,Z) :- e(X,Y), path(Y,Z). "
            ~ "sink(X) :- e(X, _), not path(X, X).");
    auto strata = stratify(p);
    // e, path, sink: three components, dependencies first.
    assert(strata.length == 3);
    size_t where(string name)
    {
        foreach (i, s; strata)
            foreach (pr; s.predicates)
                if (p.predicates[pr].name == name)
                    return i;
        assert(false);
    }

    assert(where("e") < where("path"));
    assert(where("path") < where("sink"));
    assert(strata[where("path")].recursive);
    assert(!strata[where("sink")].recursive);
    assert(strata[where("path")].rules.length == 2);

    assertThrown!StratificationException(stratify(parseProgram("win(X) :- e(X, Y), not win(Y).")));
    assertThrown!StratificationException(stratify(parseProgram(
            "a(X) :- b(X). b(X) :- c(X). c(X) :- d(X), not a(X).")));
    // Negation across components is fine; a positive cycle with a negated outside atom too.
    stratify(parseProgram("a(X) :- b(X), not c(X). b(X) :- a(X). c(1)."));
}

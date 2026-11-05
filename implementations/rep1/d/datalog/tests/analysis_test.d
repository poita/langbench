module tests.analysis_test;

import std.exception : assertNotThrown, assertThrown;

import datalog.analysis;
import datalog.errors;
import datalog.parser;

private void safe(string src)
{
    assertNotThrown!UnsafeRuleException(checkSafety(parseProgram(src)));
}

private void unsafe(string src)
{
    assertThrown!UnsafeRuleException(checkSafety(parseProgram(src)));
}

unittest
{
    safe("p(1). p(X) :- q(X). p(X) :- q(X), not r(X), X < 5, 3 != X.");
    safe("p(X) :- q(X, _).");
    safe("p(1) :- 1 < 2."); // no variables at all
    safe("p(1) :- not q(2).");
}

unittest
{
    unsafe("p(X).");
    unsafe("p(_).");
    unsafe("p(X) :- q(Y).");
    unsafe("p(X) :- q(X), not r(Y).");
    unsafe("p(X) :- q(X), not r(_).");
    unsafe("p(X) :- q(X), X < Y.");
    unsafe("p(X) :- q(X), X < _.");
    unsafe("p(Y) :- q(X), X = Y."); // comparisons never bind
    unsafe("p(X) :- q(X), Y = 5.");
    unsafe("p(X) :- not q(X), X = 1.");
}

unittest
{
    auto p = parseProgram("a(X) :- b(X). b(X) :- c(X). c(X) :- d(X). d(1).");
    auto s = stratify(p);
    // Dependencies come first in the evaluation order.
    uint pos(string name)
    {
        foreach (i, pr; p.predicates)
            if (pr.name == name)
                return s.componentOf[i];
        assert(0);
    }
    assert(pos("d") < pos("c"));
    assert(pos("c") < pos("b"));
    assert(pos("b") < pos("a"));
}

unittest
{
    auto p = parseProgram("p(X) :- q(X). q(X) :- p(X). q(1).");
    auto s = stratify(p);
    assert(s.components.length == 1);
    assert(s.components[0].length == 2);
}

unittest
{
    // Negation across components is fine; the negated predicate comes first.
    auto p = parseProgram("sink(X) :- node(X), not hasout(X). hasout(X) :- link(X, _).");
    auto s = stratify(p);
    uint comp(string name)
    {
        foreach (i, pr; p.predicates)
            if (pr.name == name)
                return s.componentOf[i];
        assert(0);
    }
    assert(comp("hasout") < comp("sink"));
}

unittest
{
    assertThrown!StratificationException(stratify(parseProgram("win(X) :- edge(X, Y), not win(Y).")));
    assertThrown!StratificationException(stratify(parseProgram("p(X) :- q(X), not r(X). r(X) :- p(X).")));
    assertThrown!StratificationException(
        stratify(parseProgram("a(X) :- b(X). b(X) :- c(X). c(X) :- d(X), not a(X).")));
    // Same name, different arity: different predicates, so no cycle.
    assertNotThrown!StratificationException(stratify(parseProgram("p(X) :- q(X), not p(X, X).")));
}

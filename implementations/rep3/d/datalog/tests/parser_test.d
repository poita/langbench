module parser_test;

import std.exception : assertThrown;
import datalog;

unittest // facts, rules and queries
{
    auto p = parseProgram("e(1,2). p(X,Y) :- e(X,Y), not q(Y), X < Y. ?- p(_, Z).");
    assert(p.rules.length == 2);
    assert(p.queries.length == 1);
    assert(p.rules[0].isFact);
    assert(p.rules[1].body.length == 3);
    assert(p.rules[1].body[1].kind == LiteralKind.negative);
    assert(p.rules[1].body[2].kind == LiteralKind.comparison);
    assert(p.queries[0].numVars == 2); // `_` and Z are distinct slots
}

unittest // predicates are identified by name and arity
{
    auto p = parseProgram("r(1). r(1,2).");
    assert(p.predicates.length == 2);
    assert(p.rules[0].head.predicate != p.rules[1].head.predicate);
}

unittest // constants are renumbered into the total order
{
    auto p = parseProgram("p(b, 10, a, -3, a0, aa, 2, a_).");
    string[] texts;
    foreach (c; p.constants) texts ~= c.text;
    assert(texts == ["-3", "2", "10", "a", "a0", "a_", "aa", "b"]);
    foreach (i, t; p.rules[0].head.args)
        assert(!t.isVar);
    assert(p.constants[p.rules[0].head.args[0].id].name == "b");
}

unittest // each _ is a fresh variable, named variables are shared
{
    auto p = parseProgram("h(X) :- a(X, _, _), b(X).");
    assert(p.rules[0].numVars == 3);
}

unittest // malformed input throws
{
    assertThrown!ParseException(parseProgram("p(1)"));
    assertThrown!ParseException(parseProgram("p(1) :- ."));
    assertThrown!ParseException(parseProgram("p()."));
}

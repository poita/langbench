module datalog_tests.parser;

import std.exception : assertThrown;
import datalog.ast;
import datalog.errors : ParseException;
import datalog.parser;

unittest // facts, rules, queries
{
    auto p = parseProgram("edge(a, 1). path(X, Y) :- edge(X, Y), not bad(Y), X < Y. ?- path(a, _).");
    assert(p.rules.length == 2 && p.queries.length == 1);
    assert(p.rules[0].isFact);
    assert(p.rules[1].body.length == 3);
    assert(p.rules[1].body[1].kind == LiteralKind.negative);
    assert(p.rules[1].body[2].kind == LiteralKind.comparison);
    assert(p.rules[1].body[2].op == CmpOp.lt);
    assert(p.rules[1].numVars == 2);
    assert(p.queries[0].numVars == 1);
}

unittest // constants are renumbered into total order
{
    auto p = parseProgram("r(b, 10, a, -2, aa, 9, a0, a_, ab).");
    assert(p.constants == ["-2", "9", "10", "a", "a0", "a_", "aa", "ab", "b"]);
    // Terms hold ranks, so integer comparison of ids is the constant order.
    auto args = p.rules[0].head.args;
    assert(p.constants[args[0].id] == "b" && args[0].id == 8);
    assert(p.constants[args[1].id] == "10");
}

unittest // predicates are keyed by name and arity
{
    auto p = parseProgram("r(a). r(a, b). ?- r(X).");
    assert(p.predicates.length == 2);
    assert(p.rules[0].head.pred != p.rules[1].head.pred);
    assert(p.queries[0].atom.pred == p.rules[0].head.pred);
}

unittest // anonymous variables are all distinct; names are clause scoped
{
    auto p = parseProgram("p(X) :- q(X, _, _). r(X, X).");
    assert(p.rules[0].numVars == 3);
    assert(p.rules[1].numVars == 1);
}

unittest // comparison with identifier on the left
{
    auto p = parseProgram("p(X) :- q(X), a < X.");
    auto l = p.rules[0].body[1];
    assert(l.kind == LiteralKind.comparison && !l.lhs.isVar && l.rhs.isVar);
}

unittest // empty program
{
    auto p = parseProgram(" % nothing\n");
    assert(p.rules.length == 0 && p.queries.length == 0);
}

unittest // malformed input
{
    assertThrown!ParseException(parseProgram("p(a)"));
    assertThrown!ParseException(parseProgram("p(a) :- ."));
    assertThrown!ParseException(parseProgram("p() ."));
}

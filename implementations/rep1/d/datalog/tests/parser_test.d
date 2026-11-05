module tests.parser_test;

import std.exception : assertThrown;

import datalog.ast;
import datalog.errors : ParseException;
import datalog.parser;

unittest
{
    auto p = parseProgram("edge(1, 2). path(X, Y) :- edge(X, Y), not blocked(Y), X < Y. ?- path(1, _).");
    assert(p.rules.length == 2);
    assert(p.queries.length == 1);
    assert(p.rules[0].isFact);
    assert(!p.rules[1].isFact);
    assert(p.rules[1].body.length == 3);
    assert(p.rules[1].body[0].kind == LiteralKind.positive);
    assert(p.rules[1].body[1].kind == LiteralKind.negative);
    assert(p.rules[1].body[2].kind == LiteralKind.comparison);
    assert(p.rules[1].body[2].op == CmpOp.lt);
    assert(p.rules[1].numVars == 2);
    assert(p.queries[0].numVars == 1); // the `_`
}

unittest
{
    // Predicates are identified by name and arity.
    auto p = parseProgram("r(a). r(a, b).");
    assert(p.predicates.length == 2);
    assert(p.predicates[0].name == "r" && p.predicates[0].arity == 1);
    assert(p.predicates[1].name == "r" && p.predicates[1].arity == 2);
    uint id;
    assert(p.findPredicate("r", 2, id) && id == 1);
    assert(!p.findPredicate("r", 3, id));
}

unittest
{
    // Predicate names and constants are separate namespaces.
    auto p = parseProgram("edge(edge, path).");
    assert(p.predicates.length == 1);
    assert(p.constants.length == 2);
}

unittest
{
    // Constants are renumbered into the total order: integers, then identifiers bytewise.
    auto p = parseProgram("c(b, a, 10, -5, a0, aa, a_, 2).");
    string[] texts;
    foreach (i; 0 .. p.constants.length)
        texts ~= p.constantText(cast(uint) i);
    assert(texts == ["-5", "2", "10", "a", "a0", "a_", "aa", "b"]);
    // Rewritten terms follow their constants.
    auto args = p.rules[0].head.args;
    assert(p.constantText(args[0].id) == "b");
    assert(p.constantText(args[3].id) == "-5");
}

unittest
{
    // Variable scoping is per clause; `_` is always fresh.
    auto p = parseProgram("p(X) :- q(X, _), r(_, X). s(X) :- t(X).");
    assert(p.rules[0].numVars == 3);
    assert(p.rules[1].numVars == 1);
    auto b = p.rules[0].body;
    assert(b[0].atom.args[1].id != b[1].atom.args[0].id);
    assert(b[0].atom.args[0].id == b[1].atom.args[1].id);
}

unittest
{
    // A bare constant may start a comparison.
    auto p = parseProgram("p(X) :- q(X), a < X, 5 >= X, X != b.");
    assert(p.rules[0].body.length == 4);
    assert(p.rules[0].body[1].kind == LiteralKind.comparison);
    assert(p.rules[0].body[2].op == CmpOp.ge);
    assert(p.rules[0].body[3].op == CmpOp.ne);
}

unittest
{
    assert(parseProgram("").rules.length == 0);
    assert(parseProgram("% nothing here\n").queries.length == 0);
}

unittest
{
    assertThrown!ParseException(parseProgram("p(a)"));
    assertThrown!ParseException(parseProgram("p(a) :- ."));
    assertThrown!ParseException(parseProgram("p(a b)."));
    assertThrown!ParseException(parseProgram("p() ."));
    assertThrown!ParseException(parseProgram("p(X) :- X ~ 1."));
}

module datalog_tests.engine;

import std.exception : assertThrown;
import datalog;

unittest // spec example 1: transitive closure
{
    assert(solve(
        "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
         path(X, Y) :- edge(X, Y).
         path(X, Z) :- edge(X, Y), path(Y, Z).
         ?- path(1, X). ?- path(4, X). ?- path(X, X).") ==
        "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n"
        ~ "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");
}

unittest // spec example 2: negation, comparisons, mixed constants
{
    assert(solve(
        "% nodes and links
         node(a). node(b). node(c). node(5). node(-2).
         link(a, b). link(b, 5). link(5, 5).
         reach(X, Y) :- link(X, Y).
         reach(X, Z) :- reach(X, Y), link(Y, Z).
         sink(X) :- node(X), not hasout(X).
         hasout(X) :- link(X, _).
         small(X) :- node(X), X < a.
         ?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X).") ==
        "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\nreach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n");
}

unittest // spec example 3: errors, with queries before the unsafe rule printing nothing
{
    assert(solve("edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X).") == "error\n");
    assert(solve("q(1). ?- q(X). p(X) :- q(Y). ?- p(X).") == "error\n");
}

unittest // no queries, empty program, undefined predicates
{
    assert(solve("") == "");
    assert(solve("p(a).") == "");
    assert(solve("?- nothing(X).") == "-- 0\n");
    assert(solve("r(a). ?- r(X, Y).") == "-- 0\n");
}

unittest // non-linear recursion needs a delta variant at every recursive position
{
    string src = "link(X, Z) :- link(X, Y), link(Y, Z).";
    foreach (i; 1 .. 33)
        src ~= "link(" ~ cast(char)('0' + i / 10) ~ cast(char)('0' + i % 10) ~ ", "
            ~ cast(char)('0' + (i + 1) / 10) ~ cast(char)('0' + (i + 1) % 10) ~ ").";
    src ~= "?- link(X, Y).";
    auto out_ = solve(src);
    import std.algorithm : endsWith;
    assert(out_.endsWith("-- 528\n")); // 33 nodes in a chain: 33*32/2 pairs
}

unittest // mutual recursion
{
    auto o = solve(
        "n(0). s(0, 1). s(1, 2). s(2, 3). s(3, 4).
         even(0).
         odd(Y) :- even(X), s(X, Y).
         even(Y) :- odd(X), s(X, Y).
         ?- even(X). ?- odd(X).");
    assert(o == "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\n-- 2\n");
}

unittest // repeated variables and constants in queries and bodies
{
    auto o = solve("e(1,1). e(1,2). e(2,2). loop(X) :- e(X, X). ?- loop(X). ?- e(X, X). ?- e(1, X). ?- e(_, _).");
    assert(o == "loop(1)\nloop(2)\n-- 2\ne(1, 1)\ne(2, 2)\n-- 2\ne(1, 1)\ne(1, 2)\n-- 2\n"
        ~ "e(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\n");
}

unittest // ground rules without positive atoms
{
    assert(solve("p(a) :- not q(b). q(c). ?- p(X).") == "p(a)\n-- 1\n");
    assert(solve("p(a) :- 1 < 2. r(a) :- 2 < 1. ?- p(X). ?- r(X).") == "p(a)\n-- 1\n-- 0\n");
}

unittest // comparisons across the integer/identifier boundary
{
    auto o = solve("v(5). v(a). v(-1). v(b). lt(X, Y) :- v(X), v(Y), X < Y. ?- lt(b, X). ?- lt(X, 5).");
    assert(o == "-- 0\nlt(-1, 5)\n-- 1\n");
    assert(solve("v(5). v(a). p(X) :- v(X), X != 5. ?- p(X).") == "p(a)\n-- 1\n");
}

unittest // Database API
{
    auto prog = parseProgram("p(1). p(2). q(X) :- p(X).");
    auto db = Database.evaluate(prog);
    assert(db.relations[1].length == 2);
    auto bad = parseProgram("p(X).");
    assertThrown!ProgramError(Database.evaluate(bad));
}

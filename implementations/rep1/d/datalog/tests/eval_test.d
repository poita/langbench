module tests.eval_test;

import std.exception : assertThrown;

import datalog;

private string run(string src)
{
    return runProgram(src);
}

unittest
{
    // SPEC example 1: transitive closure.
    assert(run("edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
                path(X, Y) :- edge(X, Y).
                path(X, Z) :- edge(X, Y), path(Y, Z).
                ?- path(1, X). ?- path(4, X). ?- path(X, X).")
            == "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n"
            ~ "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");
}

unittest
{
    // SPEC example 2: negation, comparisons, mixed constants.
    assert(run("% nodes and links
                node(a). node(b). node(c). node(5). node(-2).
                link(a, b). link(b, 5). link(5, 5).
                reach(X, Y) :- link(X, Y).
                reach(X, Z) :- reach(X, Y), link(Y, Z).
                sink(X) :- node(X), not hasout(X).
                hasout(X) :- link(X, _).
                small(X) :- node(X), X < a.
                ?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X).")
            == "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\n"
            ~ "reach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n");
}

unittest
{
    assert(run("edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X).") == "error\n");
    assert(run("q(1). ?- q(X). p(X) :- q(Y). ?- p(X).") == "error\n");
    assert(run("p(X).") == "error\n");
}

unittest
{
    assert(run("") == "");
    assert(run("p(1). q(X) :- p(X).") == ""); // no queries, no output
    assert(run("?- nothing(X).") == "-- 0\n");
    assert(run("p(1). ?- p(1, 2).") == "-- 0\n"); // other arity is an empty predicate
}

unittest
{
    // Queries see the whole program regardless of position; duplicates collapse.
    assert(run("?- p(X). p(2). p(1). p(2). p(1).") == "p(1)\np(2)\n-- 2\n");
}

unittest
{
    // Query patterns: constants, repeated variables, wildcards.
    enum db = "edge(1, 2). edge(2, 2). edge(3, 1). edge(1, 1). edge(x, x). edge(x, 2).\n";
    assert(run(db ~ "?- edge(X, X).") == "edge(1, 1)\nedge(2, 2)\nedge(x, x)\n-- 3\n");
    assert(run(db ~ "?- edge(_, 2).") == "edge(1, 2)\nedge(2, 2)\nedge(x, 2)\n-- 3\n");
    assert(run(db ~ "?- edge(_, _).") ==
            "edge(1, 1)\nedge(1, 2)\nedge(2, 2)\nedge(3, 1)\nedge(x, 2)\nedge(x, x)\n-- 6\n");
    assert(run(db ~ "?- edge(2, 1).") == "-- 0\n");
    assert(run(db ~ "?- edge(x, Y).") == "edge(x, 2)\nedge(x, x)\n-- 2\n");
}

unittest
{
    // Non-linear recursion must combine deltas in every recursive position.
    string src = "link(1,2). link(2,3). link(3,4). link(4,5). link(5,6). link(6,7). link(7,8).
                  link(X, Z) :- link(X, Y), link(Y, Z).
                  ?- link(1, X).";
    assert(run(src) == "link(1, 2)\nlink(1, 3)\nlink(1, 4)\nlink(1, 5)\nlink(1, 6)\n"
            ~ "link(1, 7)\nlink(1, 8)\n-- 7\n");
}

unittest
{
    // Mutual recursion across two predicates.
    string src = "zero(0). succ(0,1). succ(1,2). succ(2,3). succ(3,4).
                  even(X) :- zero(X).
                  even(Y) :- odd(X), succ(X, Y).
                  odd(Y) :- even(X), succ(X, Y).
                  ?- even(X). ?- odd(X).";
    assert(run(src) == "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\n-- 2\n");
}

unittest
{
    // Comparisons use the total order: integers before identifiers.
    assert(run("v(b). v(a). v(3). v(-1). lt(X, Y) :- v(X), v(Y), X < Y. ?- lt(a, Y). ?- lt(X, -1).")
            == "lt(a, b)\n-- 1\n-- 0\n");
    assert(run("v(3). v(a). p(X) :- v(X), 5 < X. q(X) :- v(X), X != 3. ?- p(X). ?- q(X).")
            == "p(a)\n-- 1\nq(a)\n-- 1\n");
}

unittest
{
    // Negation depends on a complete lower stratum, and filter placement is body-order independent.
    string a = "n(1). n(2). n(3). bad(2). good(X) :- n(X), not bad(X). ?- good(X).";
    string b = "n(1). n(2). n(3). bad(2). good(X) :- not bad(X), n(X). ?- good(X).";
    assert(run(a) == "good(1)\ngood(3)\n-- 2\n");
    assert(run(a) == run(b));
}

unittest
{
    // Ground rules with only filters in the body.
    assert(run("p(1) :- 1 < 2. q(1) :- 2 < 1. r(1) :- not s(7). ?- p(X). ?- q(X). ?- r(X).")
            == "p(1)\n-- 1\n-- 0\nr(1)\n-- 1\n");
}

unittest
{
    // A repeated variable inside one body atom selects the diagonal.
    assert(run("e(1,1). e(1,2). e(2,2). loop(X) :- e(X, X). ?- loop(X).") == "loop(1)\nloop(2)\n-- 2\n");
}

unittest
{
    // Programmatic use of the lower-level API.
    auto program = parseProgram("p(1). p(2). q(X) :- p(X), X > 1. ?- q(X).");
    auto model = evaluate(program);
    auto rows = answer(model, program.queries[0]);
    assert(rows.length == 1);
    assert(program.constantText(rows[0][0]) == "2");
    assertThrown!UnsafeRuleException(evaluate(parseProgram("p(X).")));
    assertThrown!StratificationException(evaluate(parseProgram("p(X) :- q(X), not p(X).")));
}

unittest
{
    // A long chain exercises the incremental indexes (quadratic closure).
    import std.array : appender;
    import std.conv : to;

    auto src = appender!string;
    enum n = 300;
    foreach (i; 0 .. n)
    {
        src.put("e(" ~ i.to!string ~ "," ~ (i + 1).to!string ~ ").\n");
    }
    src.put("p(X,Y) :- e(X,Y). p(X,Z) :- p(X,Y), e(Y,Z). ?- p(0, X).");
    auto out_ = run(src.data);
    assert(out_.length > 0);
    import std.algorithm.searching : endsWith;

    assert(out_.endsWith("-- " ~ n.to!string ~ "\n"));
}

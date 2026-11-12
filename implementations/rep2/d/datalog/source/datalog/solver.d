/// One-call interface: program text in, answers out.
module datalog.solver;

import datalog.analysis;
import datalog.ast;
import datalog.errors;
import datalog.eval;
import datalog.parser;

/// Parses, checks and evaluates `source` and returns the text of all query
/// answers: for each query, its matching tuples (one `p(v1, ..., vn)` per line,
/// in ascending order) followed by `-- N`.
///
/// Throws: `DatalogException` (`SyntaxException`, `UnsafeRuleException` or
/// `StratificationException`) when the program is invalid.
string solve(string source) @safe
{
    auto program = parseProgram(source);
    checkSafety(program);
    auto strat = stratify(program);
    auto model = evaluate(program, strat);
    return formatAnswers(model);
}

/// Answers every query of the model's program, in program order.
string formatAnswers(const Model model) @safe
{
    import std.array : appender;
    import std.conv : to;

    auto o = appender!string;
    foreach (ref q; model.program.queries)
    {
        auto rows = model.answer(q);
        foreach (row; rows)
        {
            o.put(model.format(q.atom.pred, row));
            o.put('\n');
        }
        o.put("-- ");
        o.put(rows.length.to!string);
        o.put('\n');
    }
    return o.data;
}

/// Like `solve`, but returns `"error\n"` for an invalid program instead of
/// throwing. This is what the command-line tool prints.
string solveOrError(string source) @safe
{
    try
        return solve(source);
    catch (DatalogException)
        return "error\n";
}

@("solver: transitive closure (spec example 1)")
@safe unittest
{
    auto out_ = solve("edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
        path(X, Y) :- edge(X, Y).
        path(X, Z) :- edge(X, Y), path(Y, Z).
        ?- path(1, X). ?- path(4, X). ?- path(X, X).");
    assert(out_ == "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n"
            ~ "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");
}

@("solver: negation, comparisons and mixed constants (spec example 2)")
@safe unittest
{
    auto out_ = solve("% nodes and links
        node(a). node(b). node(c). node(5). node(-2).
        link(a, b). link(b, 5). link(5, 5).
        reach(X, Y) :- link(X, Y).
        reach(X, Z) :- reach(X, Y), link(Y, Z).
        sink(X) :- node(X), not hasout(X).
        hasout(X) :- link(X, _).
        small(X) :- node(X), X < a.
        ?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X).");
    assert(out_ == "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\n"
            ~ "reach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n");
}

@("solver: errors take precedence over output")
@safe unittest
{
    assert(solveOrError("edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).") == "error\n");
    assert(solveOrError("q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).") == "error\n");
}

@("solver: empty programs and programs without queries print nothing")
@safe unittest
{
    assert(solve("") == "");
    assert(solve("% nothing\n") == "");
    assert(solve("p(1). q(X) :- p(X).") == "");
}

@("solver: undefined predicates and arities are empty")
@safe unittest
{
    assert(solve("r(a). ?- r(a, b). ?- zzz(X).") == "-- 0\n-- 0\n");
}

@("solver: repeated variables in rules and queries")
@safe unittest
{
    assert(solve("e(1,1). e(1,2). e(2,2). loop(X) :- e(X, X). ?- loop(X). ?- e(X, X). ?- e(A, _).")
            == "loop(1)\nloop(2)\n-- 2\ne(1, 1)\ne(2, 2)\n-- 2\ne(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\n");
}

@("solver: non-linear recursion combines deltas in every position")
@safe unittest
{
    import std.conv : to;
    import std.array : appender;

    auto src = appender!string;
    foreach (i; 0 .. 40)
        src.put("link(" ~ i.to!string ~ ", " ~ (i + 1).to!string ~ ").");
    src.put("link(X, Z) :- link(X, Y), link(Y, Z). ?- link(X, Y).");
    auto out_ = solve(src.data);
    // closure of a 41-node chain: 41*40/2 tuples
    assert(out_[$ - 7 .. $] == "-- 820\n");
}

@("solver: mutual recursion with negation on a lower stratum")
@safe unittest
{
    auto out_ = solve("num(0). num(1). num(2). num(3). succ(0,1). succ(1,2). succ(2,3).
        even(0). odd(Y) :- even(X), succ(X, Y). even(Y) :- odd(X), succ(X, Y).
        notodd(X) :- num(X), not odd(X). ?- notodd(X).");
    assert(out_ == "notodd(0)\nnotodd(2)\n-- 2\n");
}

@("solver: comparison-only and ground bodies")
@safe unittest
{
    assert(solve("p(a) :- 1 < 2. q(a) :- 2 < 1. r(b) :- not p(c). ?- p(X). ?- q(X). ?- r(X).")
            == "p(a)\n-- 1\n-- 0\nr(b)\n-- 1\n");
}

@("solver: ordering of constants")
@safe unittest
{
    auto out_ = solve("c(a). c(a0). c(a_). c(a_b). c(aa). c(ab). c(b). c(10). c(-3). c(2). ?- c(X).");
    assert(out_ == "c(-3)\nc(2)\nc(10)\nc(a)\nc(a0)\nc(a_)\nc(a_b)\nc(aa)\nc(ab)\nc(b)\n-- 10\n");
}

@("solver: linear and non-linear closure agree with Floyd-Warshall on random graphs")
unittest
{
    import std.array : appender;
    import std.conv : to;
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(42);
    foreach (trial; 0 .. 20)
    {
        enum n = 12;
        bool[n][n] reach;
        auto src = appender!string;
        foreach (_; 0 .. uniform(5, 30, rng))
        {
            auto a = uniform(0, n, rng), b = uniform(0, n, rng);
            reach[a][b] = true;
            src.put("e(" ~ a.to!string ~ "," ~ b.to!string ~ ").");
        }
        foreach (k; 0 .. n)
            foreach (i; 0 .. n)
                foreach (j; 0 .. n)
                    if (reach[i][k] && reach[k][j])
                        reach[i][j] = true;
        auto expected = appender!string;
        int count;
        foreach (i; 0 .. n)
            foreach (j; 0 .. n)
                if (reach[i][j])
                {
                    expected.put("t(" ~ i.to!string ~ ", " ~ j.to!string ~ ")\n");
                    ++count;
                }
        expected.put("-- " ~ count.to!string ~ "\n");
        auto linear = solve(src.data ~ "t(X,Y):-e(X,Y). t(X,Z):-e(X,Y),t(Y,Z). ?- t(X,Y).");
        auto nonlinear = solve(src.data ~ "t(X,Y):-e(X,Y). t(X,Z):-t(X,Y),t(Y,Z). ?- t(X,Y).");
        assert(linear == nonlinear);
        assert(sortedLines(linear) == sortedLines(expected.data));
    }
}

version (unittest)
{
    private string[] sortedLines(string s) @safe
    {
        import std.algorithm.sorting : sort;
        import std.string : splitLines;

        auto l = s.splitLines;
        l.sort();
        return l;
    }
}

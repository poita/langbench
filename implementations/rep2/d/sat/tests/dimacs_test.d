module dimacs_test;

import sat.dimacs;
import sat.solver : SolveResult;

unittest
{
    auto cnf = parseDimacs("c hi\np cnf 3 2\n1 -2 0\n2 3 0\n");
    assert(cnf.numVars == 3);
    assert(cnf.numClauses == 2);
    assert(cnf.clause(0) == [1, -2]);
    assert(cnf.clause(1) == [2, 3]);
}

unittest
{
    // Clauses spanning lines, several per line, comments and blanks anywhere,
    // tabs, no trailing newline, empty clause.
    auto cnf = parseDimacs("\n  \t c lead\np  cnf\t2   4\n1 2\nc inside\n0 -1 2 0\n\n-1 -2 0 1 -2 0\ncx\n 0");
    assert(cnf.numVars == 2);
    assert(cnf.numClauses == 5);
    assert(cnf.clause(0) == [1, 2]);
    assert(cnf.clause(1) == [-1, 2]);
    assert(cnf.clause(2) == [-1, -2]);
    assert(cnf.clause(3) == [1, -2]);
    assert(cnf.clause(4).length == 0);
}

unittest
{
    auto cnf = parseDimacs("p cnf 0 0");
    assert(cnf.numVars == 0 && cnf.numClauses == 0);
    bool[] model;
    assert(solveCnf(cnf, model) == SolveResult.sat);
    assert(cast(string) formatResult(SolveResult.sat, model) == "SAT\n0\n");
}

unittest
{
    auto cnf = parseDimacs("p cnf 12 1\n1 -2 12 0\n");
    bool[] model;
    assert(solveCnf(cnf, model) == SolveResult.sat);
    assert(satisfies(cnf, model));
    auto text = cast(string) formatResult(SolveResult.sat, model);
    assert(text[0 .. 4] == "SAT\n");
    // 12 literals plus the terminating 0, single-space separated.
    import std.array : split;
    import std.conv : to;
    auto toks = text[4 .. $ - 1].split(" ");
    assert(toks.length == 13 && toks[$ - 1] == "0");
    foreach (i, t; toks[0 .. 12])
        assert(t.to!int == (model[i] ? 1 : -1) * cast(int)(i + 1));
}

unittest
{
    assert(cast(string) formatResult(SolveResult.unsat, null) == "UNSAT\n");
    auto cnf = parseDimacs("p cnf 1 2\n1 0\n-1 0\n");
    bool[] model;
    assert(solveCnf(cnf, model) == SolveResult.unsat);
}

unittest
{
    Cnf cnf;
    cnf.numVars = 2;
    cnf.add([1, 2]);
    assert(satisfies(cnf, [false, true]));
    assert(!satisfies(cnf, [false, false]));
}

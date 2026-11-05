module tests.dimacs_test;

import sat;
import tests.helpers;

private Cnf parse(string s)
{
    return parseDimacs(cast(const(ubyte)[]) s);
}

@("header and simple clauses")
unittest
{
    auto cnf = parse("c hi\np cnf 3 2\n1 -2 0\n2 3 0\n");
    assert(cnf.numVars == 3 && cnf.declaredClauses == 2 && cnf.length == 2);
    assert(cnf[0] == [1, -2] && cnf[1] == [2, 3]);
}

@("clauses spanning lines and sharing lines, comments inside")
unittest
{
    auto cnf = parse("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n");
    assert(cnf.length == 4);
    assert(cnf[0] == [1, 2] && cnf[1] == [-1, 2] && cnf[2] == [-1, -2] && cnf[3] == [1, -2]);

    cnf = parse("p cnf 3 2\n1 2\nc interruption\n  3 0\n\t-1 0");
    assert(cnf.length == 2 && cnf[0] == [1, 2, 3] && cnf[1] == [-1]);
}

@("messy blanks, odd comments, no trailing newline")
unittest
{
    auto cnf = parse("cfoo\nc\n  \t \n p  cnf\t4  5 \n1 2\n  3 0 -1\nc mid\n-2 0 -3 4 0\t-4\n-1 0 2 -3 0");
    assert(cnf.numVars == 4 && cnf.declaredClauses == 5);
    assert(cnf.length == 5);
    assert(cnf[0] == [1, 2, 3] && cnf[1] == [-1, -2] && cnf[2] == [-3, 4]);
    assert(cnf[3] == [-4, -1] && cnf[4] == [2, -3]);
}

@("empty clauses and empty formula")
unittest
{
    auto cnf = parse("p cnf 0 0\n");
    assert(cnf.numVars == 0 && cnf.length == 0);
    cnf = parse("p cnf 2 2\n0\n1 0\n");
    assert(cnf.length == 2 && cnf[0].length == 0 && cnf[1] == [1]);
}

@("multi-digit numbers")
unittest
{
    auto cnf = parse("p cnf 2000 1\n-1999 2000 10 0\n");
    assert(cnf[0] == [-1999, 2000, 10]);
}

@("formatResult output")
unittest
{
    assert(cast(string) formatResult(Result.unsat, 3, null) == "UNSAT\n");
    bool[] vals = [true, false, true];
    assert(cast(string) formatResult(Result.sat, 3, (int v) => vals[v]) == "SAT\n1 -2 3 0\n");
    assert(cast(string) formatResult(Result.sat, 0, null) == "SAT\n0\n");
    bool[] big = new bool[12];
    big[11] = true;
    assert(cast(string) formatResult(Result.sat, 12, (int v) => big[v])
            == "SAT\n-1 -2 -3 -4 -5 -6 -7 -8 -9 -10 -11 12 0\n");
}

@("parse, solve and format end to end")
unittest
{
    auto cnf = parse("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n");
    auto s = Solver.fromCnf(cnf);
    assert(cast(string) formatResult(s.solve(), cnf.numVars, (int v) => s.modelValue(v)) == "UNSAT\n");

    cnf = parse("p cnf 3 2\n1 -2 0\n2 3 0\n");
    s = Solver.fromCnf(cnf);
    const res = s.solve();
    assert(res == Result.sat);
    auto text = cast(string) formatResult(res, 3, (int v) => s.modelValue(v));
    assert(text[0 .. 4] == "SAT\n" && text[$ - 3 .. $] == " 0\n");
}

module sat.dimacs_test;

import sat.dimacs;

unittest // basic formula
{
    auto cnf = parseDimacs("c hello\np cnf 3 2\n1 -2 0\n2 3 0\n");
    assert(cnf.numVars == 3);
    assert(cnf.numClauses == 2);
    assert(cnf.clause(0) == [1, -2]);
    assert(cnf.clause(1) == [2, 3]);
}

unittest // empty formula
{
    auto cnf = parseDimacs("p cnf 0 0\n");
    assert(cnf.numVars == 0 && cnf.numClauses == 0);
}

unittest // clauses split across lines, several per line, comments inside
{
    auto cnf = parseDimacs("p cnf 2 4\n1 2\nc inside a clause\n0 -1 2 0\n-1 -2 0 1 -2 0");
    assert(cnf.numClauses == 4);
    assert(cnf.clause(0) == [1, 2]);
    assert(cnf.clause(1) == [-1, 2]);
    assert(cnf.clause(2) == [-1, -2]);
    assert(cnf.clause(3) == [1, -2]);
}

unittest // empty clauses, repeated literals and tautologies are preserved
{
    auto cnf = parseDimacs("p cnf 2 3\n0\n1 1 -2 0\n1 -1 0\n");
    assert(cnf.numClauses == 3);
    assert(cnf.clause(0).length == 0);
    assert(cnf.clause(1) == [1, 1, -2]);
    assert(cnf.clause(2) == [1, -1]);
}

unittest // blanks, tabs, comment forms and blank lines
{
    auto cnf = parseDimacs("\nc\n   c indented\ncglued\n\n \t p   cnf \t 4  1 \n\n\t-4  \t 3 0 \t\nc end");
    assert(cnf.numVars == 4);
    assert(cnf.numClauses == 1);
    assert(cnf.clause(0) == [-4, 3]);
}

unittest // multi-digit numbers and a missing final newline
{
    auto cnf = parseDimacs("p cnf 1234 1\n-1234 1000 0");
    assert(cnf.numVars == 1234);
    assert(cnf.clause(0) == [-1234, 1000]);
}

unittest // ubyte overload
{
    immutable ubyte[] data = [0x70, 0x20, 0x63, 0x6e, 0x66, 0x20, 0x31, 0x20, 0x31, 0x0a, 0x31, 0x20, 0x30, 0x0a];
    auto cnf = parseDimacs(data);
    assert(cnf.numVars == 1 && cnf.clause(0) == [1]);
}

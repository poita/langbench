/// Reading DIMACS CNF text and writing solver answers.
module sat.dimacs;

import sat.solver;

/// A formula in conjunctive normal form, with DIMACS-style literals.
struct Cnf
{
    /// Number of variables declared by the header (variables are `1 .. numVars`).
    int numVars;
    /// Clauses as non-zero integers (`k` / `-k`); a clause may be empty.
    int[][] clauses;
}

/// Thrown for input that is not valid DIMACS CNF.
class DimacsException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

private bool isBlank(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\r';
}

/**
 * Parses DIMACS CNF text.
 *
 * Blank lines and comment lines (first non-blank character `c`) are ignored
 * anywhere. The `p cnf V C` header must precede clause data. Clauses are runs
 * of integers terminated by `0` and may span lines or share a line.
 *
 * Throws: $(D DimacsException) on a missing header, bad token, literal out of
 * range, or a clause count/termination mismatch.
 */
Cnf parseDimacs(const(char)[] text) @safe
{
    Cnf cnf;
    bool haveHeader = false;
    int declaredClauses = 0;
    int[] cur;
    size_t pos = 0;

    while (pos < text.length)
    {
        // extract one line
        size_t end = pos;
        while (end < text.length && text[end] != '\n')
            end++;
        auto line = text[pos .. end];
        pos = end + 1;

        size_t i = 0;
        while (i < line.length && isBlank(line[i]))
            i++;
        if (i == line.length || line[i] == 'c')
            continue;

        if (line[i] == 'p')
        {
            if (haveHeader)
                throw new DimacsException("duplicate header");
            auto toks = splitBlanks(line[i .. $]);
            if (toks.length != 4 || toks[0] != "p" || toks[1] != "cnf")
                throw new DimacsException("malformed header");
            const v = parseInt(toks[2]);
            const c = parseInt(toks[3]);
            if (v < 0 || c < 0)
                throw new DimacsException("negative count in header");
            cnf.numVars = v;
            declaredClauses = c;
            haveHeader = true;
            continue;
        }

        if (!haveHeader)
            throw new DimacsException("clause data before header");
        foreach (tok; splitBlanks(line[i .. $]))
        {
            const n = parseInt(tok);
            if (n == 0)
            {
                cnf.clauses ~= cur;
                cur = null;
            }
            else
            {
                if ((n < 0 ? -cast(long) n : n) > cnf.numVars)
                    throw new DimacsException("literal out of range");
                cur ~= n;
            }
        }
    }
    if (!haveHeader)
        throw new DimacsException("missing header");
    if (cur.length)
        throw new DimacsException("last clause is not terminated by 0");
    if (cnf.clauses.length != declaredClauses)
        throw new DimacsException("clause count does not match header");
    return cnf;
}

private const(char)[][] splitBlanks(const(char)[] s) pure @safe
{
    const(char)[][] r;
    size_t i = 0;
    while (i < s.length)
    {
        while (i < s.length && isBlank(s[i]))
            i++;
        const b = i;
        while (i < s.length && !isBlank(s[i]))
            i++;
        if (i > b)
            r ~= s[b .. i];
    }
    return r;
}

private int parseInt(const(char)[] t) pure @safe
{
    size_t i = 0;
    bool neg = false;
    if (t.length && t[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i == t.length)
        throw new DimacsException("bad integer");
    long v = 0;
    foreach (c; t[i .. $])
    {
        if (c < '0' || c > '9')
            throw new DimacsException("bad integer");
        v = v * 10 + (c - '0');
        if (v > int.max)
            throw new DimacsException("integer too large");
    }
    return cast(int)(neg ? -v : v);
}

/// Result of $(D solveCnf).
struct SolveResult
{
    /// True if the formula is satisfiable.
    bool satisfiable;
    /// If satisfiable, `model[i]` is the value of variable `i + 1`
    /// (length `numVars`); otherwise empty.
    bool[] model;
}

/// Solves a parsed formula with a fresh $(D Solver).
SolveResult solveCnf(const Cnf cnf)
{
    auto s = new Solver(cnf.numVars);
    foreach (c; cnf.clauses)
        if (!s.addClause(c))
            return SolveResult(false, null);
    if (s.solve() == SolveStatus.unsat)
        return SolveResult(false, null);
    return SolveResult(true, s.model.dup);
}

/**
 * Renders a result in the output format of the command-line tool:
 * `UNSAT\n`, or `SAT\n` followed by one line listing every variable as a
 * signed literal and a final `0`.
 */
string formatResult(const SolveResult r) pure @safe
{
    import std.array : appender;
    import std.conv : to;

    if (!r.satisfiable)
        return "UNSAT\n";
    auto o = appender!string;
    o.put("SAT\n");
    foreach (i, b; r.model)
    {
        if (!b)
            o.put('-');
        o.put((i + 1).to!string);
        o.put(' ');
    }
    o.put("0\n");
    return o.data;
}

unittest
{
    auto c = parseDimacs("c hi\np cnf 3 2\n1 -2 0\n  c x\n2 3\n0\n");
    assert(c.numVars == 3);
    assert(c.clauses == [[1, -2], [2, 3]]);
}

unittest
{
    // several clauses on one line, clause split across lines, no final newline
    auto c = parseDimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0");
    assert(c.clauses == [[1, 2], [-1, 2], [-1, -2], [1, -2]]);
}

unittest
{
    // comments between the numbers of one clause, tabs, empty clause
    auto c = parseDimacs("\t p\tcnf  2   2 \n1\ncfoo\n\t-2 0\n\n0\n");
    assert(c.clauses == [[1, -2], []]);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!DimacsException(parseDimacs("1 0\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1 1\n2 0\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1 1\n1\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1 2\n1 0\n"));
}

unittest
{
    assert(formatResult(SolveResult(false)) == "UNSAT\n");
    assert(formatResult(SolveResult(true, [true, false, true])) == "SAT\n1 -2 3 0\n");
    assert(formatResult(SolveResult(true, [])) == "SAT\n0\n");
}

unittest
{
    assert(solveCnf(parseDimacs("p cnf 0 0\n")).satisfiable);
    assert(!solveCnf(parseDimacs("p cnf 2 4\n1 2 0 -1 2 0 -1 -2 0 1 -2 0\n")).satisfiable);
    assert(!solveCnf(parseDimacs("p cnf 1 1\n0\n")).satisfiable);
}

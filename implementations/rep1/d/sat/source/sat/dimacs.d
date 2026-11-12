/// Reading DIMACS CNF text and writing the solver's answer.
module sat.dimacs;

import std.array : Appender, appender;

/// A formula in conjunctive normal form, with DIMACS-style literals.
struct Cnf
{
    /// Number of variables `V`; literals refer to `1 .. V`.
    int numVars;
    /// Clauses as lists of non-zero integers (`k` = variable k true, `-k` = false).
    int[][] clauses;
}

/// Thrown when the input is not valid DIMACS CNF.
class DimacsException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Parses DIMACS CNF text.
 *
 * Lines are classified by their first non-blank (space or tab) character:
 * blank lines and `c` comment lines are ignored, the single `p cnf V C`
 * line is the header, and everything else is clause data. Clauses are runs of
 * non-zero integers terminated by `0`; they may span lines and share lines.
 *
 * The declared clause count is not enforced, but a literal outside
 * `1 .. V`, a missing header, or a final clause lacking its `0` throws
 * $(D DimacsException).
 */
Cnf parseDimacs(const(char)[] text) pure @safe
{
    Cnf cnf;
    bool haveHeader = false;
    int[] current;
    size_t i = 0;
    immutable n = text.length;

    while (i < n)
    {
        // Find the extent of this line.
        size_t end = i;
        while (end < n && text[end] != '\n')
            ++end;
        auto line = text[i .. end];
        i = end + 1;

        size_t p = 0;
        while (p < line.length && isBlank(line[p]))
            ++p;
        if (p == line.length || line[p] == 'c')
            continue;

        if (line[p] == 'p')
        {
            if (haveHeader)
                throw new DimacsException("duplicate header line");
            cnf.numVars = parseHeader(line[p .. $]);
            haveHeader = true;
            continue;
        }

        if (!haveHeader)
            throw new DimacsException("clause data before the 'p cnf' header");

        while (p < line.length)
        {
            if (isBlank(line[p]))
            {
                ++p;
                continue;
            }
            immutable lit = parseInt(line, p);
            if (lit == 0)
            {
                cnf.clauses ~= current;
                current = null;
            }
            else
            {
                immutable v = lit < 0 ? -lit : lit;
                if (v > cnf.numVars)
                    throw new DimacsException("literal outside 1..V");
                current ~= lit;
            }
        }
    }
    if (!haveHeader)
        throw new DimacsException("missing 'p cnf' header");
    if (current.length != 0)
        throw new DimacsException("last clause is not terminated by 0");
    return cnf;
}

private bool isBlank(char c) pure nothrow @nogc @safe { return c == ' ' || c == '\t'; }

private int parseInt(const(char)[] line, ref size_t p) pure @safe
{
    bool negative = false;
    if (p < line.length && line[p] == '-')
    {
        negative = true;
        ++p;
    }
    if (p >= line.length || line[p] < '0' || line[p] > '9')
        throw new DimacsException("expected an integer");
    long value = 0;
    while (p < line.length && line[p] >= '0' && line[p] <= '9')
    {
        value = value * 10 + (line[p] - '0');
        if (value > int.max)
            throw new DimacsException("integer out of range");
        ++p;
    }
    if (p < line.length && !isBlank(line[p]))
        throw new DimacsException("unexpected character in clause data");
    return cast(int) (negative ? -value : value);
}

private int parseHeader(const(char)[] line) pure @safe
{
    size_t p = 0;
    string[3] expect = ["p", "cnf", ""];
    int[2] numbers;
    int field = 0;
    while (field < 4)
    {
        while (p < line.length && isBlank(line[p]))
            ++p;
        if (p >= line.length)
            throw new DimacsException("incomplete 'p cnf V C' header");
        if (field < 2)
        {
            size_t q = p;
            while (q < line.length && !isBlank(line[q]))
                ++q;
            if (line[p .. q] != expect[field])
                throw new DimacsException("malformed header; expected 'p cnf V C'");
            p = q;
        }
        else
        {
            numbers[field - 2] = parseInt(line, p);
            if (numbers[field - 2] < 0)
                throw new DimacsException("negative count in header");
        }
        ++field;
    }
    return numbers[0];
}

/// Checks whether `model` (indexed by 0-based variable) satisfies every clause of `cnf`.
bool satisfies(const ref Cnf cnf, const(bool)[] model) pure nothrow @nogc @safe
{
    foreach (clause; cnf.clauses)
    {
        bool ok = false;
        foreach (lit; clause)
        {
            immutable v = (lit < 0 ? -lit : lit) - 1;
            if (model[v] == (lit > 0))
            {
                ok = true;
                break;
            }
        }
        if (!ok)
            return false;
    }
    return true;
}

/**
 * Formats an answer as the CLI prints it.
 *
 * Returns `"UNSAT\n"`, or `"SAT\n"` followed by one line with a literal for
 * every variable in order and a closing `0`.
 */
string formatAnswer(bool satisfiable, const(bool)[] model) pure @safe
{
    if (!satisfiable)
        return "UNSAT\n";
    auto buf = appender!string();
    buf.reserve(8 + model.length * 7);
    buf.put("SAT\n");
    foreach (i, value; model)
    {
        putInt(buf, value ? cast(int) (i + 1) : -cast(int) (i + 1));
        buf.put(' ');
    }
    buf.put("0\n");
    return buf.data;
}

private void putInt(ref Appender!string buf, int x) pure @safe
{
    char[12] tmp;
    size_t k = tmp.length;
    bool negative = x < 0;
    uint u = negative ? -cast(uint) x : x;
    do
    {
        tmp[--k] = cast(char) ('0' + u % 10);
        u /= 10;
    }
    while (u != 0);
    if (negative)
        tmp[--k] = '-';
    buf.put(tmp[k .. $]);
}

@safe pure unittest
{
    auto cnf = parseDimacs("c hi\np cnf 3 2\n1 -2 0\n2 3 0");
    assert(cnf.numVars == 3);
    assert(cnf.clauses == [[1, -2], [2, 3]]);
}

@safe pure unittest
{
    // Clauses spanning lines, sharing a line, comments in the middle, odd blanks.
    auto cnf = parseDimacs("  p \t cnf  2   4 \n1 2\n\t\n0 -1 2 0\nc mid\n-1 -2 0 1 -2 0\ncfoo\n");
    assert(cnf.numVars == 2);
    assert(cnf.clauses == [[1, 2], [-1, 2], [-1, -2], [1, -2]]);
}

@safe pure unittest
{
    auto cnf = parseDimacs("p cnf 0 0\n");
    assert(cnf.numVars == 0 && cnf.clauses.length == 0);

    cnf = parseDimacs("p cnf 2 2\n0\n1 1 -2 0");
    assert(cnf.clauses.length == 2 && cnf.clauses[0].length == 0);
    assert(cnf.clauses[1] == [1, 1, -2]);
}

@safe pure unittest
{
    import std.exception : assertThrown;

    assertThrown!DimacsException(parseDimacs("1 0\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1 1\n1\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1 1\n2 0\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1\n"));
    assertThrown!DimacsException(parseDimacs("p cnf 1 1\n1x 0\n"));
}

@safe pure unittest
{
    assert(formatAnswer(false, null) == "UNSAT\n");
    assert(formatAnswer(true, []) == "SAT\n0\n");
    assert(formatAnswer(true, [true, false, true]) == "SAT\n1 -2 3 0\n");
    auto cnf = parseDimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    assert(satisfies(cnf, [true, false, true]));
    assert(!satisfies(cnf, [false, true, false]));
}

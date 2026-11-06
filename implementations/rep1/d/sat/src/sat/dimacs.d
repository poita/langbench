/// DIMACS CNF input parsing and result formatting.
module sat.dimacs;

import sat.solver : Result;

/// A parsed CNF formula in flat storage.
struct Cnf
{
    /// Number of variables declared in the `p cnf` header.
    int numVars;
    /// Number of clauses declared in the header.
    int declaredClauses;
    /// All literals (DIMACS form, no terminating zeros), clause after clause.
    int[] literals;
    /// `ends[i]` is the index in `literals` one past the end of clause `i`.
    size_t[] ends;

    /// Number of clauses actually read.
    size_t length() const pure nothrow @safe @nogc
    {
        return ends.length;
    }

    /// The literals of clause `i`.
    const(int)[] opIndex(size_t i) const pure nothrow @safe @nogc
    {
        return literals[i == 0 ? 0 : ends[i - 1] .. ends[i]];
    }
}

/**
 * Parse a DIMACS CNF text. Blank lines and `c` comment lines are skipped
 * anywhere, clauses may span lines and share lines, and the `p cnf V C` header
 * is read once. Input is assumed well formed.
 */
Cnf parseDimacs(const(ubyte)[] data) pure nothrow @trusted
{
    Cnf cnf;
    const(ubyte)* p = data.ptr;
    const(ubyte)* end = p + data.length;

    static bool blank(ubyte c) pure nothrow @safe @nogc
    {
        return c == ' ' || c == '\t';
    }

    while (p < end)
    {
        while (p < end && blank(*p))
            p++;
        if (p >= end)
            break;
        ubyte c = *p;
        if (c == '\n')
        {
            p++;
            continue;
        }
        if (c == 'c')
        {
            while (p < end && *p != '\n')
                p++;
            continue;
        }
        if (c == 'p')
        {
            p++;
            // skip the format word ("cnf")
            while (p < end && blank(*p))
                p++;
            while (p < end && !blank(*p) && *p != '\n')
                p++;
            cnf.numVars = cast(int) readUint(p, end);
            cnf.declaredClauses = cast(int) readUint(p, end);
            while (p < end && *p != '\n')
                p++;
            continue;
        }
        // Clause data: integers separated by blanks until end of line.
        while (p < end && *p != '\n')
        {
            if (blank(*p))
            {
                p++;
                continue;
            }
            bool negative = false;
            if (*p == '-')
            {
                negative = true;
                p++;
            }
            long v = 0;
            while (p < end && *p >= '0' && *p <= '9')
                v = v * 10 + (*p++ - '0');
            if (v == 0)
            {
                cnf.ends ~= cnf.literals.length;
            }
            else
                cnf.literals ~= cast(int)(negative ? -v : v);
        }
    }
    return cnf;
}

/// ditto
Cnf parseDimacs(const(char)[] text) pure nothrow @trusted
{
    return parseDimacs(cast(const(ubyte)[]) text);
}

private long readUint(ref const(ubyte)* p, const(ubyte)* end) pure nothrow @system @nogc
{
    while (p < end && (*p == ' ' || *p == '\t'))
        p++;
    long v = 0;
    while (p < end && *p >= '0' && *p <= '9')
        v = v * 10 + (*p++ - '0');
    return v;
}

/**
 * Format a solver answer as the program output: `UNSAT\n`, or `SAT\n`
 * followed by one line with a literal per variable and a closing `0`.
 *
 * Params:
 *   result = the solver's verdict
 *   numVars = number of variables
 *   isTrue = truth value of variable `v` (0-based); only called when SAT
 */
ubyte[] formatResult(Result result, int numVars, scope bool delegate(int) isTrue)
{
    ubyte[] buf;
    if (result != Result.sat)
    {
        buf = cast(ubyte[]) "UNSAT\n".dup;
        return buf;
    }
    buf.reserve(8 + cast(size_t) numVars * 7);
    buf ~= cast(const(ubyte)[]) "SAT\n";
    ubyte[12] tmp;
    foreach (v; 0 .. numVars)
    {
        if (!isTrue(v))
            buf ~= '-';
        uint n = v + 1;
        size_t k = tmp.length;
        do
        {
            tmp[--k] = cast(ubyte)('0' + n % 10);
            n /= 10;
        }
        while (n);
        buf ~= tmp[k .. $];
        buf ~= ' ';
    }
    buf ~= '0';
    buf ~= '\n';
    return buf;
}

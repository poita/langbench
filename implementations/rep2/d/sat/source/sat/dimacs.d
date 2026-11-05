/**
 * DIMACS CNF reading and result formatting.
 *
 * The parser works directly on a byte buffer (no per-token strings). It
 * accepts blank lines, `c` comment lines anywhere, one `p cnf V C` header,
 * and clauses that span lines or share a line.
 */
module sat.dimacs;

import sat.solver : Solver, SolveResult;

/// A parsed CNF formula in DIMACS (1-based, signed) literals.
struct Cnf
{
    /// Number of variables declared by the `p cnf` header.
    int numVars;
    /// Flat literal storage; clause `i` is `literals[starts[i] .. starts[i+1]]`.
    int[] literals;
    /// Clause start offsets into `literals`, with one extra terminating entry.
    size_t[] starts = [0];

    /// Number of clauses.
    size_t numClauses() const pure nothrow @nogc @safe { return starts.length - 1; }

    /// The literals of clause `i`.
    const(int)[] clause(size_t i) const pure nothrow @nogc @safe
    {
        return literals[starts[i] .. starts[i + 1]];
    }

    /// Appends a clause (DIMACS literals, without the terminating 0).
    void add(const(int)[] lits) pure nothrow @safe
    {
        literals ~= lits;
        starts ~= literals.length;
    }
}

/**
 * Parses DIMACS CNF text.
 *
 * Input is assumed well formed; a trailing unterminated clause is ignored.
 */
Cnf parseDimacs(const(ubyte)[] text) pure nothrow @safe
{
    Cnf cnf;
    size_t pos = 0;
    const n = text.length;
    bool inClause = false;
    cnf.literals.reserve(n / 3 + 1);

    static bool isBlank(ubyte b) pure nothrow @nogc @safe { return b == ' ' || b == '\t' || b == '\r'; }

    // Parses a decimal integer at `pos` (after skipping blanks); returns false
    // at end of line / input.
    bool nextInt(ref int value)
    {
        while (pos < n && isBlank(text[pos]))
            ++pos;
        if (pos >= n || text[pos] == '\n')
            return false;
        bool negative = false;
        if (text[pos] == '-')
        {
            negative = true;
            ++pos;
        }
        else if (text[pos] == '+')
            ++pos;
        int v = 0;
        while (pos < n && text[pos] >= '0' && text[pos] <= '9')
        {
            v = v * 10 + (text[pos] - '0');
            ++pos;
        }
        value = negative ? -v : v;
        return true;
    }

    while (pos < n)
    {
        while (pos < n && isBlank(text[pos]))
            ++pos;
        if (pos >= n)
            break;
        const ch = text[pos];
        if (ch == '\n')
        {
            ++pos;
            continue;
        }
        if (ch == 'c')
        {
            while (pos < n && text[pos] != '\n')
                ++pos;
            continue;
        }
        if (ch == 'p')
        {
            ++pos;
            // Skip the "cnf" word, then read V (and ignore C).
            while (pos < n && isBlank(text[pos]))
                ++pos;
            while (pos < n && !isBlank(text[pos]) && text[pos] != '\n')
                ++pos;
            int v = 0;
            if (nextInt(v))
                cnf.numVars = v;
            while (pos < n && text[pos] != '\n')
                ++pos;
            continue;
        }
        int v;
        while (nextInt(v))
        {
            if (v == 0)
            {
                cnf.starts ~= cnf.literals.length;
                inClause = false;
            }
            else
            {
                cnf.literals ~= v;
                inClause = true;
            }
        }
    }
    // A final clause lacking its 0 terminator is dropped.
    if (inClause)
        cnf.literals.length = cnf.starts[$ - 1];
    return cnf;
}

/// Convenience overload for text held in a string.
Cnf parseDimacs(string text) pure nothrow @trusted
{
    return parseDimacs(cast(const(ubyte)[]) text);
}

/// Loads every clause of `cnf` into `solver`, in order. Returns false as soon
/// as the solver detects the formula is unsatisfiable.
bool loadInto(ref const Cnf cnf, Solver solver)
{
    foreach (i; 0 .. cnf.numClauses)
        if (!solver.addClause(cnf.clause(i)))
            return false;
    return true;
}

/// Solves a parsed formula. On `sat`, `model[i]` is the value of variable i+1.
SolveResult solveCnf(ref const Cnf cnf, out bool[] model)
{
    auto solver = new Solver(cnf.numVars);
    if (!loadInto(cnf, solver))
        return SolveResult.unsat;
    const r = solver.solve();
    if (r == SolveResult.sat)
        model = solver.model.dup;
    return r;
}

/// Checks that `model` (index i = variable i+1) satisfies every clause.
bool satisfies(ref const Cnf cnf, const(bool)[] model) pure nothrow @nogc @safe
{
    foreach (i; 0 .. cnf.numClauses)
    {
        bool ok = false;
        foreach (l; cnf.clause(i))
        {
            const v = (l < 0 ? -l : l) - 1;
            if (model[v] == (l > 0))
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

/// Formats a solver answer in the output format: `UNSAT\n`, or `SAT\n`
/// followed by one signed literal per variable and a final `0`.
ubyte[] formatResult(SolveResult result, const(bool)[] model) pure nothrow @safe
{
    ubyte[] buf;
    if (result == SolveResult.unsat)
    {
        buf = cast(ubyte[]) "UNSAT\n".dup;
        return buf;
    }
    buf.reserve(4 + model.length * 7 + 2);
    buf ~= cast(const(ubyte)[]) "SAT\n";
    foreach (i, value; model)
    {
        if (!value)
            buf ~= '-';
        appendUint(buf, cast(uint) i + 1);
        buf ~= ' ';
    }
    buf ~= '0';
    buf ~= '\n';
    return buf;
}

private void appendUint(ref ubyte[] buf, uint x) pure nothrow @safe
{
    ubyte[10] tmp;
    size_t k = tmp.length;
    do
    {
        tmp[--k] = cast(ubyte)('0' + x % 10);
        x /= 10;
    }
    while (x != 0);
    buf ~= tmp[k .. $];
}

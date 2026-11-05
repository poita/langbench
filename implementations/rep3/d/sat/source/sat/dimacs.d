/**
 * DIMACS CNF parsing.
 *
 * The parser works on a byte buffer and scans integers by hand, so parsing is
 * linear in the input size and allocates only the result arrays.
 */
module sat.dimacs;

/// A formula in conjunctive normal form, as read from a DIMACS file.
struct Cnf
{
    /// Number of variables `V` from the `p cnf V C` header.
    int numVars;

    /// All literals of all clauses back to back (DIMACS numbering, no terminators).
    int[] literals;

    /// `starts[i] .. starts[i+1]` is the slice of `literals` for clause `i`;
    /// `starts.length == numClauses + 1`.
    size_t[] starts = [0];

    /// Number of clauses actually present.
    size_t numClauses() const @safe pure nothrow @nogc { return starts.length - 1; }

    /// Literals of clause `i` (may be empty).
    const(int)[] clause(size_t i) const @safe pure nothrow @nogc
    {
        return literals[starts[i] .. starts[i + 1]];
    }

    /// Append a clause (convenience for building formulas in code).
    void addClause(scope const(int)[] lits...) @safe pure nothrow
    {
        literals ~= lits;
        starts ~= literals.length;
    }
}

/**
 * Parse a DIMACS CNF document.
 *
 * Comment lines (first non-blank character `c`) and blank lines are skipped
 * anywhere, the `p cnf V C` header supplies `numVars`, and the remaining
 * integers are split into clauses at each `0`. Clauses may span lines and
 * several clauses may share a line. Input is assumed to be well formed; a
 * trailing unterminated clause is ignored.
 */
Cnf parseDimacs(scope const(ubyte)[] data) @safe pure nothrow
{
    Cnf cnf;
    size_t i = 0;
    immutable n = data.length;
    cnf.literals.reserve(n / 3 + 1);

    while (i < n)
    {
        immutable ch = data[i];
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        {
            ++i;
        }
        else if (ch == 'c')
        {
            while (i < n && data[i] != '\n')
                ++i;
        }
        else if (ch == 'p')
        {
            ++i;
            while (i < n && (data[i] < '0' || data[i] > '9') && data[i] != '\n')
                ++i; // skip "cnf" and blanks up to V
            long v = 0;
            while (i < n && data[i] >= '0' && data[i] <= '9')
                v = v * 10 + (data[i++] - '0');
            cnf.numVars = cast(int) v;
            // the clause count is not needed: clauses are delimited by 0
            while (i < n && data[i] != '\n')
                ++i;
        }
        else
        {
            bool negative = false;
            if (ch == '-')
            {
                negative = true;
                ++i;
            }
            long v = 0;
            while (i < n && data[i] >= '0' && data[i] <= '9')
                v = v * 10 + (data[i++] - '0');
            if (v == 0 && !negative)
            {
                cnf.starts ~= cnf.literals.length;
            }
            else
            {
                cnf.literals ~= cast(int)(negative ? -v : v);
            }
        }
    }
    return cnf;
}

/// ditto
Cnf parseDimacs(scope const(char)[] text) @trusted pure nothrow
{
    return parseDimacs(cast(const(ubyte)[]) text);
}

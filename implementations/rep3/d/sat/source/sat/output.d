/**
 * Rendering of solver results in the textual format of the command-line tool.
 */
module sat.output;

/**
 * Render a verdict.
 *
 * Unsatisfiable: `UNSAT\n`. Satisfiable: `SAT\n` followed by one line with
 * `l1 l2 ... lV 0` where `li` is `i` if `model[i-1]` is true and `-i`
 * otherwise. The whole text is built in one buffer.
 */
ubyte[] renderResult(bool satisfiable, scope const(bool)[] model) @safe pure nothrow
{
    ubyte[] buf;
    if (!satisfiable)
    {
        buf = cast(ubyte[]) "UNSAT\n".dup;
        return buf;
    }
    buf.reserve(8 + model.length * 7);
    buf ~= cast(const(ubyte)[]) "SAT\n";
    foreach (i, value; model)
    {
        if (!value)
            buf ~= '-';
        appendNumber(buf, i + 1);
        buf ~= ' ';
    }
    buf ~= '0';
    buf ~= '\n';
    return buf;
}

private void appendNumber(ref ubyte[] buf, size_t x) @safe pure nothrow
{
    ubyte[20] tmp;
    size_t n = 0;
    do
    {
        tmp[n++] = cast(ubyte)('0' + x % 10);
        x /= 10;
    }
    while (x != 0);
    while (n > 0)
        buf ~= tmp[--n];
}

/// Rendering of resolutions in the command-line output format.
module depresolve.output;

import std.array : appender;
import depresolve.resolver;

/**
 * Formats a resolution: one `name MAJOR.MINOR.PATCH` line per pick in name
 * order, or the single line `unsatisfiable`.
 */
string format(const Resolution r) pure @safe
{
    if (!r.satisfiable)
        return "unsatisfiable\n";
    auto buf = appender!string();
    foreach (ref p; r.picks)
    {
        buf ~= p.name;
        buf ~= ' ';
        putNumber(buf, p.version_.major);
        buf ~= '.';
        putNumber(buf, p.version_.minor);
        buf ~= '.';
        putNumber(buf, p.version_.patch);
        buf ~= '\n';
    }
    return buf[];
}

private void putNumber(Buf)(ref Buf buf, ulong n) pure @safe
{
    char[20] tmp;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n != 0);
    buf ~= tmp[i .. $];
}

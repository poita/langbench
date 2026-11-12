/// Command-line front end: DIMACS CNF on stdin, `SAT`/`UNSAT` answer on stdout.
module app;

import std.stdio : stdin, stdout, stderr;
import sat;

int main()
{
    ubyte[] raw;
    foreach (chunk; stdin.byChunk(1 << 16))
        raw ~= chunk;
    Cnf cnf;
    try
        cnf = parseDimacs(cast(const(char)[]) raw);
    catch (DimacsException e)
    {
        stderr.writeln("sat: ", e.msg);
        return 2;
    }
    stdout.write(formatResult(solveCnf(cnf)));
    return 0;
}

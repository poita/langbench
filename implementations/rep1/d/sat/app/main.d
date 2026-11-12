/// Command-line front end: DIMACS CNF on stdin, `SAT` + model or `UNSAT` on stdout.
module app.main;

import std.stdio : stderr, stdin, stdout;
import std.array : appender;

import sat;

private enum usage = "usage: sat < input.cnf\n"
    ~ "Reads a DIMACS CNF formula on standard input and prints\n"
    ~ "  SAT\\n<l1> ... <lV> 0\\n   or   UNSAT\\n\n";

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.write(usage);
        return args[1] == "-h" || args[1] == "--help" ? 0 : 2;
    }

    auto buf = appender!(ubyte[])();
    foreach (chunk; stdin.byChunk(1 << 16))
        buf.put(chunk);
    const text = cast(const(char)[]) buf.data;

    Cnf cnf;
    try
        cnf = parseDimacs(text);
    catch (DimacsException e)
    {
        stderr.writeln("sat: ", e.msg);
        return 2;
    }

    const result = solve(cnf);
    stdout.write(formatAnswer(result.satisfiable, result.model));
    return 0;
}

/// Command-line front end: reads DIMACS CNF on stdin, prints SAT/UNSAT.
module main;

import std.array : appender;
import std.stdio : stdin, stdout;

import sat;

int main()
{
    auto input = appender!(ubyte[])();
    ubyte[65536] chunk;
    for (;;)
    {
        auto got = stdin.rawRead(chunk[]);
        if (got.length == 0)
            break;
        input ~= got;
    }

    const cnf = parseDimacs(input[]);
    bool[] model;
    const result = solveCnf(cnf, model);
    stdout.rawWrite(formatResult(result, model));
    stdout.flush();
    return 0;
}

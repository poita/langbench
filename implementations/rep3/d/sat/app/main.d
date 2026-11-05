/**
 * Command-line tool: reads a DIMACS CNF formula on standard input and prints
 * `SAT` plus a model line, or `UNSAT`, on standard output.
 */
module main;

import std.stdio : stdin, stdout;
import sat;

int main()
{
    // One bulk read of all of standard input.
    ubyte[] input;
    ubyte[1 << 16] chunk;
    while (true)
    {
        auto got = stdin.rawRead(chunk[]);
        if (got.length == 0)
            break;
        input ~= got;
    }

    auto cnf = parseDimacs(input);
    auto result = solve(cnf);
    stdout.rawWrite(renderResult(result.satisfiable, result.model));
    stdout.flush();
    return 0;
}

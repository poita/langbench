/// The command-line front end: Datalog program on stdin, answers on stdout.
module datalog.cli;

import datalog.solver : solveOrError;
import std.stdio : stderr, stdin, stdout;

/// Reads a whole program from standard input, writes the answers (or `error`)
/// to standard output and returns the process exit status (0 unless I/O fails).
int runCli(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: ", args[0], " < program.dl");
        return 2;
    }
    auto buf = new ubyte[](0);
    foreach (chunk; stdin.byChunk(1 << 16))
        buf ~= chunk;
    stdout.write(solveOrError(cast(string) buf.idup));
    return 0;
}

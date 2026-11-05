/// Command-line front end: DIMACS CNF on stdin, `SAT`/`UNSAT` result on stdout.
module main;

import std.stdio : stdin, stdout;

import sat;

/// Read all of standard input with large chunked reads.
private ubyte[] readAll()
{
    ubyte[] buf = new ubyte[1 << 16];
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        auto got = stdin.rawRead(buf[len .. $]);
        if (got.length == 0)
            break;
        len += got.length;
    }
    return buf[0 .. len];
}

int main()
{
    const cnf = parseDimacs(readAll());
    auto solver = Solver.fromCnf(cnf);
    const result = solver.solve();
    auto out_ = formatResult(result, cnf.numVars, (int v) => solver.modelValue(v));
    stdout.rawWrite(out_);
    stdout.flush();
    return 0;
}

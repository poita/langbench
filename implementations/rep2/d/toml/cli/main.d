/**
 * Command-line front end.
 *
 * Reads all of stdin. The first line is the mode, `decode` or `encode`; the
 * rest is the document. Writes the result to stdout and always exits 0.
 *
 *   decode: TOML in, tagged JSON out (or the word `error`)
 *   encode: tagged JSON in, canonical TOML out
 *
 * Diagnostics go to stderr. All the work is done by `toml.convert`.
 */
module cli.main;

import std.stdio : stderr, stdin, stdout;

import toml.convert : processRequest;

/// Reads all of stdin into memory.
ubyte[] readAll()
{
    ubyte[] data;
    ubyte[65_536] buf;
    while (true)
    {
        auto got = stdin.rawRead(buf[]);
        if (got.length == 0)
            break;
        data ~= got;
    }
    return data;
}

int main()
{
    string diagnostic;
    immutable output = processRequest(readAll(), diagnostic);
    if (diagnostic.length)
        stderr.writeln("toml-cli: ", diagnostic);
    stdout.write(output);
    return 0;
}

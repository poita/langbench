/// protowire command-line tool: reads schema + requests on stdin, writes one
/// result line per request on stdout. See README.md.
module app.main;

import std.stdio : stderr, stdin, stdout;
import protowire.errors : ProtowireException;
import protowire.request : processInput;

int main()
{
    // Read all of stdin.
    ubyte[] input;
    foreach (chunk; stdin.byChunk(1 << 16))
        input ~= chunk;

    try
    {
        auto output = processInput(cast(const(char)[]) input);
        stdout.rawWrite(output);
    }
    catch (ProtowireException e)
    {
        // A schema that cannot be parsed: report on stderr (ignored by the contract).
        stderr.writeln("protowire: ", e.msg);
    }
    return 0;
}

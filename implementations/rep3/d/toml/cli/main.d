/// Command-line front end: `decode` turns TOML on stdin into tagged JSON,
/// `encode` turns tagged JSON on stdin into canonical TOML.
///
/// Input: a mode line (`decode` or `encode`) followed by the document.
module main;

import std.stdio : stdin, stdout;
import toml;

int main()
{
    ubyte[] buf;
    foreach (chunk; stdin.byChunk(1 << 20))
        buf ~= chunk;

    size_t nl = 0;
    while (nl < buf.length && buf[nl] != '\n') nl++;
    immutable mode = cast(string) buf[0 .. nl].idup;
    immutable doc = nl < buf.length ? cast(string) buf[nl + 1 .. $].idup : "";

    string output;
    if (mode == "decode")
    {
        try
            output = toTaggedJson(parseToml(doc)) ~ "\n";
        catch (Exception)
            output = "error\n";
    }
    else if (mode == "encode")
    {
        try
            output = toToml(fromTaggedJson(doc));
        catch (Exception)
            output = "error\n";
    }
    else
        output = "error\n";

    stdout.rawWrite(output);
    return 0;
}

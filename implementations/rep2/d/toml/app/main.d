/// Command-line front end: `toml` reads a mode line (`decode` or `encode`)
/// and a document from stdin and writes the result to stdout.
module main;

import std.array : appender;
import std.stdio : stdin, stdout;
import toml;

int main()
{
    auto input = readAll();
    size_t nl = 0;
    while (nl < input.length && input[nl] != '\n')
        nl++;
    auto mode = input[0 .. nl];
    string doc = nl < input.length ? input[nl + 1 .. $] : "";

    string output;
    if (mode == "decode")
    {
        try
            output = toTaggedJson(parseToml(doc));
        catch (TomlException)
            output = "error";
    }
    else if (mode == "encode")
    {
        try
            output = toToml(fromTaggedJson(doc));
        catch (TomlException)
            output = "error";
    }
    else
        output = "error";

    stdout.rawWrite(output);
    if (output.length == 0 || output[$ - 1] != '\n')
        stdout.rawWrite("\n");
    return 0;
}

string readAll()
{
    auto app = appender!(ubyte[]);
    ubyte[] chunk = new ubyte[1 << 20];
    for (;;)
    {
        auto got = stdin.rawRead(chunk);
        if (got.length == 0)
            break;
        app.put(got);
    }
    return cast(string) app.data;
}

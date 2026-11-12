/**
 * Command-line front end.
 *
 * Reads all of stdin. The first line is the mode, `decode` or `encode`; the
 * rest is the document. `decode` prints the document as tagged JSON (or the
 * word `error` if it is not valid TOML); `encode` reads tagged JSON and
 * prints canonical TOML.
 */
module app;

import std.stdio : stdin, stdout;
import toml;

/// Reads the whole of stdin.
ubyte[] readAll()
{
    ubyte[] data;
    auto chunk = new ubyte[1 << 20];
    for (;;)
    {
        auto got = stdin.rawRead(chunk);
        if (got.length == 0)
            break;
        data ~= got;
    }
    return data;
}

int main()
{
    auto input = cast(const(char)[]) readAll();
    size_t eol = 0;
    while (eol < input.length && input[eol] != '\n')
        ++eol;
    const mode = input[0 .. eol];
    const body_ = eol < input.length ? input[eol + 1 .. $] : input[$ .. $];

    string output;
    if (mode == "encode")
    {
        output = taggedJsonToToml(body_);
    }
    else
    {
        try
            output = tomlToTaggedJson(body_) ~ "\n";
        catch (TomlException)
            output = "error\n";
    }
    stdout.rawWrite(output);
    return 0;
}

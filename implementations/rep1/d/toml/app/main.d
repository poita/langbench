/**
 * Command-line tool. Reads `decode\n<TOML>` or `encode\n<tagged JSON>` on
 * stdin and writes the result to stdout (see SPEC.md).
 */
module main;

import std.stdio : stdin, stdout;
import toml;

int main()
{
    ubyte[] data;
    {
        enum chunk = 1 << 20;
        size_t len = 0;
        data.length = chunk;
        for (;;)
        {
            auto got = stdin.rawRead(data[len .. $]);
            if (got.length == 0)
                break;
            len += got.length;
            if (len == data.length)
                data.length = data.length * 2;
        }
        data.length = len;
    }
    auto all = cast(string) data;

    size_t nl = 0;
    while (nl < all.length && all[nl] != '\n')
        ++nl;
    immutable mode = all[0 .. nl];
    immutable body_ = nl < all.length ? all[nl + 1 .. $] : "";

    string result;
    if (mode == "encode")
    {
        try
            result = taggedJsonToToml(body_);
        catch (Exception)
            result = "\n";
    }
    else
    {
        try
            result = tomlToTaggedJson(body_) ~ "\n";
        catch (Exception)
            result = "error\n";
    }
    stdout.rawWrite(result);
    return 0;
}

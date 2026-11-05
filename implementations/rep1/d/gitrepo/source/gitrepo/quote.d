/// Git's default path quoting (`core.quotePath` on).
module gitrepo.quote;

import gitrepo.oid : hexDigits;

/// Appends `name` to `sink`, quoted if it contains a byte outside `0x20..0x7e`, a `"` or a `\`.
void appendQuoted(Sink)(ref Sink sink, scope const(char)[] name)
{
    bool plain = true;
    foreach (c; name)
    {
        if (c < 0x20 || c > 0x7e || c == '"' || c == '\\')
        {
            plain = false;
            break;
        }
    }
    if (plain)
    {
        sink.put(cast(const(ubyte)[]) name);
        return;
    }
    sink.put(cast(ubyte) '"');
    foreach (char c; name)
    {
        switch (c)
        {
        case 7: sink.put(cast(const(ubyte)[]) `\a`); break;
        case 8: sink.put(cast(const(ubyte)[]) `\b`); break;
        case 9: sink.put(cast(const(ubyte)[]) `\t`); break;
        case 10: sink.put(cast(const(ubyte)[]) `\n`); break;
        case 11: sink.put(cast(const(ubyte)[]) `\v`); break;
        case 12: sink.put(cast(const(ubyte)[]) `\f`); break;
        case 13: sink.put(cast(const(ubyte)[]) `\r`); break;
        case '"': sink.put(cast(const(ubyte)[]) `\"`); break;
        case '\\': sink.put(cast(const(ubyte)[]) `\\`); break;
        default:
            if (c < 0x20 || c >= 0x7f)
            {
                sink.put(cast(ubyte) '\\');
                sink.put(cast(ubyte)('0' + ((c >> 6) & 7)));
                sink.put(cast(ubyte)('0' + ((c >> 3) & 7)));
                sink.put(cast(ubyte)('0' + (c & 7)));
            }
            else
                sink.put(cast(ubyte) c);
        }
    }
    sink.put(cast(ubyte) '"');
}

/// The quoted form of `name` as a string.
string quotePath(scope const(char)[] name) @trusted
{
    import std.array : appender;

    auto sink = appender!(ubyte[]);
    appendQuoted(sink, name);
    return cast(string) sink.data;
}

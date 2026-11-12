/// Git's default path quoting (`core.quotePath` behaviour).
module gitrepo.quote;

import std.array : Appender;

/// Append `name` to `sink`, quoted if necessary: names made only of bytes in
/// `0x20..0x7e` other than `"` and `\` are written as they are; anything else
/// is wrapped in double quotes with C-style escapes and three-digit octal
/// escapes for non-printable and non-ASCII bytes.
void appendQuoted(ref Appender!(ubyte[]) sink, scope const(ubyte)[] name) @safe pure nothrow
{
    bool plain = true;
    foreach (b; name)
        if (b < 0x20 || b > 0x7e || b == '"' || b == '\\')
        {
            plain = false;
            break;
        }
    if (plain)
    {
        sink.put(name);
        return;
    }
    sink.put('"');
    foreach (b; name)
    {
        switch (b)
        {
        case 7:
            sink.put(cast(const(ubyte)[]) "\\a");
            break;
        case 8:
            sink.put(cast(const(ubyte)[]) "\\b");
            break;
        case 9:
            sink.put(cast(const(ubyte)[]) "\\t");
            break;
        case 10:
            sink.put(cast(const(ubyte)[]) "\\n");
            break;
        case 11:
            sink.put(cast(const(ubyte)[]) "\\v");
            break;
        case 12:
            sink.put(cast(const(ubyte)[]) "\\f");
            break;
        case 13:
            sink.put(cast(const(ubyte)[]) "\\r");
            break;
        case '"':
            sink.put(cast(const(ubyte)[]) "\\\"");
            break;
        case '\\':
            sink.put(cast(const(ubyte)[]) "\\\\");
            break;
        default:
            if (b < 0x20 || b >= 0x7f)
            {
                sink.put('\\');
                sink.put(cast(ubyte)('0' + (b >> 6)));
                sink.put(cast(ubyte)('0' + ((b >> 3) & 7)));
                sink.put(cast(ubyte)('0' + (b & 7)));
            }
            else
                sink.put(b);
        }
    }
    sink.put('"');
}

/// `name` quoted as by `appendQuoted`, as a new array.
ubyte[] quoted(scope const(ubyte)[] name) @safe pure nothrow
{
    Appender!(ubyte[]) a;
    appendQuoted(a, name);
    return a[];
}

unittest
{
    assert(cast(string) quoted(cast(const(ubyte)[]) "plain name.txt") == "plain name.txt");
    assert(cast(string) quoted(cast(const(ubyte)[]) "café.txt") == `"caf\303\251.txt"`);
    assert(cast(string) quoted(cast(const(ubyte)[]) "quote\"and\\slash.txt") == `"quote\"and\\slash.txt"`);
    assert(cast(string) quoted(cast(const(ubyte)[]) "a\tb\x01c\x7f") == `"a\tb\001c\177"`);
    assert(cast(string) quoted(cast(const(ubyte)[]) "") == "");
}

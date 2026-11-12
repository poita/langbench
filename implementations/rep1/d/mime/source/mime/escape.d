/// Escaping used by the textual dump format.
module mime.escape;

import std.array : appender;

@safe:

private immutable hexDigits = "0123456789abcdef";

/// `esc(s)`: backslash-escapes `\`, LF, CR, TAB and `"`, and writes any other
/// control character (below 0x20, 0x7F, or U+0080..U+009F) as `\xHH`.
string esc(string s) pure
{
    auto app = appender!string();
    foreach (dchar c; s)
    {
        switch (c)
        {
        case '\\': app.put(`\\`); break;
        case '\n': app.put(`\n`); break;
        case '\r': app.put(`\r`); break;
        case '\t': app.put(`\t`); break;
        case '"': app.put(`\"`); break;
        default:
            if (c < 0x20 || (c >= 0x7F && c <= 0x9F))
            {
                app.put(`\x`);
                app.put(hexDigits[(c >> 4) & 0xF]);
                app.put(hexDigits[c & 0xF]);
            }
            else
                app.put(c);
        }
    }
    return app.data;
}

/// `q(s)`: `s` escaped and wrapped in double quotes.
string q(string s) pure
{
    return "\"" ~ esc(s) ~ "\"";
}

/// Eight lower-case hexadecimal digits.
string hex8(uint v) pure nothrow
{
    char[8] buf;
    foreach_reverse (i; 0 .. 8)
    {
        buf[i] = hexDigits[v & 0xF];
        v >>= 4;
    }
    return buf.idup;
}

pure unittest
{
    assert(esc("a\\b\n\r\t\"\x01\x7f\u0085é") == `a\\b\n\r\t\"\x01\x7f\x85é`);
    assert(q("x") == `"x"`);
    assert(hex8(0x000e0007) == "000e0007");
    assert(hex8(1) == "00000001");
}

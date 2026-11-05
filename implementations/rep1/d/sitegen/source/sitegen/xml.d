/// Escaping for the hand-written XML outputs.
module sitegen.xml;

import std.array : Appender;

/// Append `s` with `&`, `<` and `>` escaped.
void putXmlText(ref Appender!(char[]) o, const(char)[] s) pure nothrow @safe
{
    size_t run = 0;
    foreach (i, c; s)
    {
        string rep;
        switch (c)
        {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        default: continue;
        }
        o.put(s[run .. i]);
        o.put(rep);
        run = i + 1;
    }
    o.put(s[run .. $]);
}

/// Append `s` escaped for use in a double-quoted attribute: like
/// `putXmlText`, plus `"` as `&quot;`.
void putXmlAttr(ref Appender!(char[]) o, const(char)[] s) pure nothrow @safe
{
    size_t run = 0;
    foreach (i, c; s)
    {
        string rep;
        switch (c)
        {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        case '"': rep = "&quot;"; break;
        default: continue;
        }
        o.put(s[run .. i]);
        o.put(rep);
        run = i + 1;
    }
    o.put(s[run .. $]);
}

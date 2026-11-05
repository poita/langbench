/// Structured header values (`Content-Type`, `Content-Disposition`,
/// `Content-Transfer-Encoding`): a value proper plus `;`-separated
/// parameters, including RFC 2231 continuations and extended values.
module mime.params;

import mime.ascii;
import mime.buffer;
import mime.charset;
import mime.encodedword;
import mime.syntax;

/// A parsed structured header value.
struct StructuredValue
{
    /// The first segment, unmodified (callers strip and lower-case it).
    string value;
    /// Effective parameters, RFC 2231 assembled, in order of first appearance.
    Param[] params;

    /// Looks up an effective parameter by lower-case name.
    bool find(string name, out string result) const @safe pure nothrow @nogc
    {
        foreach (ref p; params)
            if (p.name == name)
            {
                result = p.value;
                return true;
            }
        return false;
    }

    /// The value proper, stripped of blanks and lower-cased.
    string valueProper() const @safe pure nothrow
    {
        return toLowerAscii(stripBlanks(value).idup);
    }
}

/// One effective parameter.
struct Param
{
    string name;
    string value;
}

private struct RawParam
{
    string name;
    string value;
}

/// Splits `v` at every `;` outside a quoted string.
private string[] splitSegments(string v) @safe pure nothrow
{
    string[] segs;
    size_t start = 0;
    size_t i = 0;
    while (i < v.length)
    {
        immutable c = v[i];
        if (c == '"')
            i = scanQuoted(v, i).end;
        else if (c == ';')
        {
            segs ~= v[start .. i];
            i++;
            start = i;
        }
        else
            i++;
    }
    segs ~= v[start .. $];
    return segs;
}

private RawParam[] collectRaw(string[] segs) @safe pure nothrow
{
    RawParam[] raws;
    foreach (seg; segs)
    {
        size_t eq = size_t.max;
        foreach (k, c; seg)
            if (c == '=')
            {
                eq = k;
                break;
            }
        if (eq == size_t.max)
            continue;
        immutable name = toLowerAscii(stripBlanks(seg[0 .. eq]).idup);
        auto val = stripBlanks(seg[eq + 1 .. $]);
        string value = val.idup;
        if (val.length > 0 && val[0] == '"')
            value = scanQuoted(val.idup, 0).text;
        bool dup = false;
        foreach (ref r; raws)
            if (r.name == name)
            {
                dup = true;
                break;
            }
        if (!dup)
            raws ~= RawParam(name, value);
    }
    return raws;
}

private struct Segment
{
    string number; // decimal digits, no leading zeros (canonical)
    bool extended;
    string value;
}

private struct Group
{
    string base;
    Segment[] segments;
    bool hasExtended;
    string extendedValue;
    bool hasPlain;
    string plainValue;
    bool plainFirst; // the plain value appeared first (only affects ordering)
}

private string stripLeadingZeros(string d) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i + 1 < d.length && d[i] == '0')
        i++;
    return d[i .. $];
}

private bool numberLess(string a, string b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return a.length < b.length;
    return a < b;
}

/// Classifies a raw parameter name. Returns 0 for plain, 1 for `base*N`
/// (`ext` tells whether it ended in `*`), 2 for `base*`.
private int classify(string name, out string base, out string number, out bool ext) @safe pure nothrow
{
    ext = name.length > 0 && name[$ - 1] == '*';
    string rest = ext ? name[0 .. $ - 1] : name;
    // base*N
    size_t k = rest.length;
    while (k > 0 && isDigit(rest[k - 1]))
        k--;
    if (k < rest.length && k >= 2 && rest[k - 1] == '*')
    {
        base = rest[0 .. k - 1];
        number = stripLeadingZeros(rest[k .. $]);
        return 1;
    }
    ext = false;
    if (name.length >= 2 && name[$ - 1] == '*')
    {
        base = name[0 .. $ - 1];
        return 2;
    }
    return 0;
}

private ubyte[] percentDecode(const(char)[] s) @safe pure nothrow
{
    auto o = new ubyte[](s.length);
    size_t n = 0;
    for (size_t i = 0; i < s.length;)
    {
        if (s[i] == '%' && i + 2 < s.length && hexValue(s[i + 1]) >= 0 && hexValue(s[i + 2]) >= 0)
        {
            o[n++] = cast(ubyte)(hexValue(s[i + 1]) * 16 + hexValue(s[i + 2]));
            i += 3;
        }
        else
            o[n++] = s[i++];
    }
    return o[0 .. n];
}

/// Splits `charset'language'text`; returns the charset and the text.
private void splitExtended(string v, out string charset, out string text) @safe pure nothrow
{
    size_t q1 = size_t.max, q2 = size_t.max;
    foreach (i, c; v)
        if (c == '\'')
        {
            if (q1 == size_t.max)
                q1 = i;
            else
            {
                q2 = i;
                break;
            }
        }
    if (q2 == size_t.max)
    {
        charset = "us-ascii";
        text = v;
        return;
    }
    charset = v[0 .. q1];
    if (charset.length == 0)
        charset = "us-ascii";
    text = v[q2 + 1 .. $];
}

private string decodeExtended(string v) @safe pure nothrow
{
    string cs, text;
    splitExtended(v, cs, text);
    return decode(percentDecode(text), cs);
}

private string assemble(ref Group g) @safe pure nothrow
{
    // order by number; first in appearance wins among equal numbers
    Segment[] segs;
    foreach (s; g.segments)
    {
        bool dup = false;
        foreach (u; segs)
            if (u.number == s.number)
            {
                dup = true;
                break;
            }
        if (!dup)
            segs ~= s;
    }
    // stable insertion sort by numeric value
    foreach (i; 1 .. segs.length)
    {
        auto x = segs[i];
        size_t j = i;
        while (j > 0 && numberLess(x.number, segs[j - 1].number))
        {
            segs[j] = segs[j - 1];
            j--;
        }
        segs[j] = x;
    }
    string charset = "us-ascii";
    auto o = ByteBuffer(64);
    foreach (s; segs)
    {
        if (s.extended)
        {
            string text = s.value;
            if (s.number == "0")
            {
                string cs;
                splitExtended(s.value, cs, text);
                charset = cs;
            }
            o.put(percentDecode(text));
        }
        else
            o.put(s.value);
    }
    return decode(o.data, charset);
}

/// Parses a structured header value from its unfolded raw text.
StructuredValue parseStructured(string raw) @safe pure nothrow
{
    auto segs = splitSegments(raw);
    StructuredValue sv;
    sv.value = segs[0];
    auto raws = collectRaw(segs[1 .. $]);

    Group[] groups;
    ref Group groupFor(string base) @safe pure nothrow
    {
        foreach (i; 0 .. groups.length)
            if (groups[i].base == base)
                return groups[i];
        groups ~= Group(base);
        return groups[$ - 1];
    }

    // Order of output: by first appearance of each effective name.
    foreach (ref r; raws)
    {
        string base, number;
        bool ext;
        immutable kind = classify(r.name, base, number, ext);
        if (kind == 0)
        {
            auto g = &groupFor(r.name);
            g.hasPlain = true;
            g.plainValue = decodeUnstructured(r.value);
        }
        else if (kind == 1)
        {
            auto g = &groupFor(base);
            g.segments ~= Segment(number, ext, r.value);
        }
        else
        {
            auto g = &groupFor(base);
            g.hasExtended = true;
            g.extendedValue = r.value;
        }
    }
    foreach (ref g; groups)
    {
        if (g.segments.length > 0)
            sv.params ~= Param(g.base, assemble(g));
        else if (g.hasExtended)
            sv.params ~= Param(g.base, decodeExtended(g.extendedValue));
        else
            sv.params ~= Param(g.base, g.plainValue);
    }
    return sv;
}

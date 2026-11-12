/// Structured header values (`Content-Type` and friends) with RFC 2231
/// parameter assembly.
module mime.params;

import std.algorithm : sort;
import std.array : appender;
import mime.charset : decode;
import mime.encodedword : decodeUnstructured;
import mime.text;
import mime.transfer : hexDigit;

@safe:

/// A parsed `value; name=value; ...` header.
struct Structured
{
    /// The first segment, stripped of blanks (case preserved).
    string value;
    /// Effective parameters by lower-cased name.
    string[string] params;

    /// Returns the parameter's value, or null when absent.  Use `has` to
    /// distinguish an absent parameter from an empty one.
    string get(string name) const pure nothrow
    {
        if (auto p = name in params)
            return *p;
        return null;
    }

    /// Whether the parameter is present.
    bool has(string name) const pure nothrow
    {
        return (name in params) !is null;
    }
}

private struct RawParam
{
    string name;
    string value;
}

private ubyte[] bytesOf(string s) pure nothrow @trusted
{
    return cast(ubyte[]) s.dup;
}

/// Splits `raw` at top-level `;` (not inside a quoted string).
private string[] splitSegments(string raw) pure nothrow
{
    string[] segs;
    size_t start = 0, i = 0;
    while (i < raw.length)
    {
        const c = raw[i];
        if (c == '"')
        {
            size_t end;
            readQuoted(raw, i, end);
            i = end;
        }
        else if (c == ';')
        {
            segs ~= raw[start .. i];
            ++i;
            start = i;
        }
        else
            ++i;
    }
    segs ~= raw[start .. $];
    return segs;
}

private ubyte[] percentDecode(string s) pure nothrow
{
    auto app = appender!(ubyte[])();
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '%' && i + 2 < s.length && hexDigit(s[i + 1]) >= 0 && hexDigit(s[i + 2]) >= 0)
        {
            app.put(cast(ubyte)(hexDigit(s[i + 1]) * 16 + hexDigit(s[i + 2])));
            i += 3;
        }
        else
        {
            app.put(cast(ubyte) s[i]);
            ++i;
        }
    }
    return app.data;
}

/// Splits `charset'language'text`; with fewer than two `'` the whole string
/// is the text.  An empty charset means us-ascii.
private void splitExtended(string v, out string charset, out string text) pure nothrow
{
    charset = "us-ascii";
    text = v;
    size_t first = size_t.max;
    foreach (i, char c; v)
        if (c == '\'')
        {
            first = i;
            break;
        }
    if (first == size_t.max)
        return;
    size_t second = size_t.max;
    foreach (i; first + 1 .. v.length)
        if (v[i] == '\'')
        {
            second = i;
            break;
        }
    if (second == size_t.max)
        return;
    if (first > 0)
        charset = v[0 .. first];
    text = v[second + 1 .. $];
}

private enum NameKind { plain, segment, extended }

/// Classifies a parameter name as `base`, `base*N`/`base*N*` or `base*`.
private NameKind classify(string name, out string base, out string num, out bool extSeg) pure nothrow
{
    base = name;
    num = null;
    extSeg = false;
    string rest = name;
    bool star = false;
    if (rest.length > 0 && rest[$ - 1] == '*')
    {
        star = true;
        rest = rest[0 .. $ - 1];
    }
    // base*N pattern
    size_t d = rest.length;
    while (d > 0 && rest[d - 1] >= '0' && rest[d - 1] <= '9') --d;
    if (d < rest.length && d >= 2 && rest[d - 1] == '*')
    {
        base = rest[0 .. d - 1];
        string digits = rest[d .. $];
        size_t z = 0;
        while (z + 1 < digits.length && digits[z] == '0') ++z;
        num = digits[z .. $];
        extSeg = star;
        return NameKind.segment;
    }
    if (star && rest.length > 0)
    {
        base = rest;
        return NameKind.extended;
    }
    return NameKind.plain;
}

private struct Segment
{
    string num;
    string value;
    bool ext;
}

private struct Group
{
    string base;
    Segment[] segs;
    bool hasExt;
    string ext;
    bool hasPlain;
    string plain;
}

private string[string] assemble(RawParam[] raws) pure nothrow
{
    Group[] groups;
    size_t[string] index;
    foreach (r; raws)
    {
        string base, num;
        bool extSeg;
        const kind = classify(r.name, base, num, extSeg);
        size_t gi;
        if (auto p = base in index)
            gi = *p;
        else
        {
            gi = groups.length;
            index[base] = gi;
            groups ~= Group(base);
        }
        final switch (kind)
        {
        case NameKind.plain:
            groups[gi].hasPlain = true;
            groups[gi].plain = r.value;
            break;
        case NameKind.extended:
            groups[gi].hasExt = true;
            groups[gi].ext = r.value;
            break;
        case NameKind.segment:
            groups[gi].segs ~= Segment(num, r.value, extSeg);
            break;
        }
    }

    string[string] result;
    foreach (ref g; groups)
    {
        if (g.segs.length != 0)
        {
            // Keep the first segment of each number, then order numerically.
            Segment[] uniq;
            bool[string] seen;
            foreach (s; g.segs)
            {
                if (s.num in seen)
                    continue;
                seen[s.num] = true;
                uniq ~= s;
            }
            uniq.sort!((a, b) => a.num.length != b.num.length
                       ? a.num.length < b.num.length : a.num < b.num);
            string charset = "us-ascii";
            auto bytes = appender!(ubyte[])();
            foreach (s; uniq)
            {
                if (s.ext)
                {
                    string text = s.value;
                    if (s.num == "0")
                        splitExtended(s.value, charset, text);
                    bytes.put(percentDecode(text));
                }
                else
                    bytes.put(bytesOf(s.value));
            }
            result[g.base] = decode(bytes.data, charset);
        }
        else if (g.hasExt)
        {
            string charset, text;
            splitExtended(g.ext, charset, text);
            result[g.base] = decode(percentDecode(text), charset);
        }
        else
            result[g.base] = decodeUnstructured(g.plain);
    }
    return result;
}

/// Parses a `Content-Type`-style header value (the unfolded raw text).
Structured parseStructured(string raw) pure nothrow
{
    auto segs = splitSegments(raw);
    Structured s;
    s.value = stripBlanks(segs[0]);
    RawParam[] raws;
    bool[string] seen;
    foreach (seg; segs[1 .. $])
    {
        size_t eq = size_t.max;
        foreach (i, char c; seg)
            if (c == '=')
            {
                eq = i;
                break;
            }
        if (eq == size_t.max)
            continue;
        const name = toLowerAscii(stripBlanks(seg[0 .. eq]));
        if (name in seen)
            continue;
        seen[name] = true;
        string value = stripBlanks(seg[eq + 1 .. $]);
        if (value.length != 0 && value[0] == '"')
        {
            size_t end;
            value = readQuoted(value, 0, end);
        }
        raws ~= RawParam(name, value);
    }
    s.params = assemble(raws);
    return s;
}

/// Returns `(type, subtype)` if `value` (already stripped and lower-cased)
/// is `token/token`, otherwise empty strings.
void splitMediaType(string value, out string type, out string subtype) pure nothrow @nogc
{
    static bool isTokenChar(char c) pure nothrow @nogc
    {
        switch (c)
        {
        case ' ', '\t', '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=':
            return false;
        default:
            return true;
        }
    }
    size_t slash = size_t.max;
    foreach (i, char c; value)
    {
        if (c == '/')
        {
            if (slash != size_t.max)
                return;
            slash = i;
        }
        else if (!isTokenChar(c))
            return;
    }
    if (slash == size_t.max || slash == 0 || slash + 1 == value.length)
        return;
    type = value[0 .. slash];
    subtype = value[slash + 1 .. $];
}

pure nothrow unittest
{
    auto p = parseStructured(`multipart/mixed; boundary="X"; Charset=utf-8`);
    assert(p.value == "multipart/mixed");
    assert(p.get("boundary") == "X" && p.get("charset") == "utf-8");
    assert(!p.has("nothing"));
}

pure nothrow unittest
{
    static string fn(string params)
    {
        return parseStructured("x; " ~ params).get("filename");
    }
    assert(fn(`filename="report.pdf"`) == "report.pdf");
    assert(fn("filename*=utf-8''a%C3%A9.txt") == "aé.txt");
    assert(fn(`filename*0="long"; filename*1="name.txt"`) == "longname.txt");
    assert(fn(`filename*0*=utf-8''a%C3%A9; filename*1=".txt"`) == "aé.txt");
    assert(fn(`filename="=?utf-8?Q?a=C3=A9.txt?="`) == "aé.txt");
    assert(fn(`filename=two words.bin`) == "two words.bin");
    assert(fn("filename*=''caf%E9.txt") == "caf\uFFFD.txt");
    assert(fn(`filename*0=a; filename*2=c; filename*10=j`) == "acj");
    assert(fn(`filename="a\\"; x=1`) == `a\`);
    assert(fn(`filename*0=a; filename*00=b; filename*1=c; filename*1*=d`) == "ac");
    assert(fn(`filename=plain; filename*=utf-8''ext`) == "ext");
    assert(fn(`filename*=utf-8''ext; filename*0=num`) == "num");
    assert(fn(`filename=one; filename=two`) == "one");
    assert(fn(`filename*07=x`) == "x");
    assert(parseStructured(`x; *0=v`).get("*0") == "v");
    assert(parseStructured("x; a=\"semi;colon\"; b=2").get("b") == "2");
}

pure nothrow @nogc unittest
{
    string t, s;
    splitMediaType("text/plain", t, s);
    assert(t == "text" && s == "plain");
    splitMediaType("text", t, s);
    assert(t.length == 0);
    splitMediaType("a/b/c", t, s);
    assert(t.length == 0);
    splitMediaType("a/ b", t, s);
    assert(t.length == 0);
}

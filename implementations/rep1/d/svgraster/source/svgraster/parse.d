/// Parsers for the small value grammars of SVG: numbers, lengths, colours,
/// opacities, transform lists and `style` declarations.
module svgraster.parse;

import std.ascii : isDigit, isWhite, isHexDigit, toLower;
import std.conv : to;
import std.math : tan, sin, cos, PI, floor, isFinite;
import std.string : indexOf, strip;
import svgraster.colors;
import svgraster.geom;

/// Skip ASCII whitespace.
void skipSpace(const(char)[] s, ref size_t i) pure nothrow @safe @nogc
{
    while (i < s.length && isWhite(s[i]))
        ++i;
}

/// Skip whitespace and commas (the separator of number lists).
void skipSeparators(const(char)[] s, ref size_t i) pure nothrow @safe @nogc
{
    while (i < s.length && (isWhite(s[i]) || s[i] == ','))
        ++i;
}

/// Scan a number starting exactly at `i` (no leading whitespace is skipped).
/// On success advances `i` past it and stores the value in `v`.
bool scanNumber(const(char)[] s, ref size_t i, out double v)
{
    size_t j = i;
    immutable n = s.length;
    if (j < n && (s[j] == '+' || s[j] == '-'))
        ++j;
    size_t intDigits = 0, fracDigits = 0;
    while (j < n && isDigit(s[j]))
    {
        ++j;
        ++intDigits;
    }
    if (j < n && s[j] == '.')
    {
        ++j;
        while (j < n && isDigit(s[j]))
        {
            ++j;
            ++fracDigits;
        }
    }
    if (intDigits + fracDigits == 0)
        return false;
    if (j < n && (s[j] == 'e' || s[j] == 'E'))
    {
        size_t k = j + 1;
        if (k < n && (s[k] == '+' || s[k] == '-'))
            ++k;
        if (k < n && isDigit(s[k]))
        {
            while (k < n && isDigit(s[k]))
                ++k;
            j = k;
        }
    }
    v = toDouble(s[i .. j]);
    i = j;
    return true;
}

private double toDouble(const(char)[] tok)
{
    // std.conv wants digits on both sides of the point; normalise "5." / ".5".
    char[] buf;
    buf.reserve(tok.length + 2);
    size_t k = 0;
    if (k < tok.length && (tok[k] == '+' || tok[k] == '-'))
        buf ~= tok[k++];
    if (k >= tok.length || tok[k] == '.')
        buf ~= '0';
    while (k < tok.length)
    {
        buf ~= tok[k];
        if (tok[k] == '.' && (k + 1 >= tok.length || !isDigit(tok[k + 1])))
            buf ~= '0';
        ++k;
    }
    try
        return to!double(buf);
    catch (Exception)
        return 0;
}

/// Parse a number, allowing surrounding whitespace, that must span the whole
/// of `s`.
bool parseNumberExact(const(char)[] s, out double v)
{
    size_t i = 0;
    skipSpace(s, i);
    if (!scanNumber(s, i, v))
        return false;
    skipSpace(s, i);
    return i == s.length;
}

/// Parse a length: a number optionally followed by `px`. A value that does not
/// start with a number yields `false`; trailing text after the number is
/// ignored.
bool parseLength(const(char)[] s, out double v)
{
    size_t i = 0;
    skipSpace(s, i);
    return scanNumber(s, i, v);
}

/// Parse a length attribute, returning `dflt` if it is missing or malformed.
double lengthOr(const(char)[] s, double dflt)
{
    double v;
    if (s !is null && parseLength(s, v))
        return v;
    return dflt;
}

/// Parse a list of numbers separated by whitespace and/or commas. Parsing
/// stops at the first token that is not a number.
double[] parseNumberList(const(char)[] s)
{
    double[] r;
    size_t i = 0;
    while (true)
    {
        skipSeparators(s, i);
        double v;
        if (i >= s.length || !scanNumber(s, i, v))
            break;
        r ~= v;
    }
    return r;
}

/// Parse an opacity (a number or a percentage), clamped to `[0, 1]`.
/// Returns `false` (leaving `v` untouched) for anything else.
bool parseOpacity(const(char)[] s, ref double v)
{
    size_t i = 0;
    skipSpace(s, i);
    double x;
    if (!scanNumber(s, i, x))
        return false;
    if (i < s.length && s[i] == '%')
    {
        x /= 100;
        ++i;
    }
    skipSpace(s, i);
    if (i != s.length)
        return false;
    v = x < 0 ? 0 : (x > 1 ? 1 : x);
    return true;
}

private ubyte roundChannel(double v)
{
    // Clamp to [0,255], then round halves up (values are non-negative).
    if (!(v > 0))
        return 0;
    if (v >= 255)
        return 255;
    return cast(ubyte) floor(v + 0.5);
}

private string lowerCase(const(char)[] s)
{
    char[] o = new char[s.length];
    foreach (k, ch; s)
        o[k] = toLower(ch);
    return o.idup;
}

/// The result of parsing a paint value.
struct ParsedColor
{
    /// `none`.
    bool none;
    /// `currentColor`.
    bool current;
    /// The colour when neither of the above.
    Rgb rgb;
}

/// Parse a paint/colour value. Returns `false` if `s` is not in the grammar.
bool parseColor(const(char)[] sIn, out ParsedColor pc)
{
    auto s = strip(sIn);
    if (s.length == 0)
        return false;
    immutable low = lowerCase(s);
    if (low == "none")
    {
        pc.none = true;
        return true;
    }
    if (low == "currentcolor")
    {
        pc.current = true;
        return true;
    }
    if (s[0] == '#')
    {
        auto h = s[1 .. $];
        foreach (ch; h)
            if (!isHexDigit(ch))
                return false;
        uint hv(char ch) { return isDigit(ch) ? ch - '0' : (ch | 0x20) - 'a' + 10; }
        if (h.length == 3)
        {
            pc.rgb = Rgb(cast(ubyte)(hv(h[0]) * 17), cast(ubyte)(hv(h[1]) * 17),
                    cast(ubyte)(hv(h[2]) * 17));
            return true;
        }
        if (h.length == 6)
        {
            pc.rgb = Rgb(cast(ubyte)(hv(h[0]) * 16 + hv(h[1])),
                    cast(ubyte)(hv(h[2]) * 16 + hv(h[3])), cast(ubyte)(hv(h[4]) * 16 + hv(h[5])));
            return true;
        }
        return false;
    }
    if (low.length > 4 && low[0 .. 4] == "rgb(")
    {
        immutable close = low.indexOf(')');
        if (close < 0)
            return false;
        auto body_ = low[4 .. close];
        ubyte[3] ch;
        size_t i = 0;
        foreach (k; 0 .. 3)
        {
            skipSeparators(body_, i);
            double v;
            if (!scanNumber(body_, i, v))
                return false;
            if (i < body_.length && body_[i] == '%')
            {
                ++i;
                v = (v < 0 ? 0 : (v > 100 ? 100 : v)) * 255.0 / 100.0;
            }
            ch[k] = roundChannel(v);
        }
        pc.rgb = Rgb(ch[0], ch[1], ch[2]);
        return true;
    }
    return lookupColorName(low, pc.rgb);
}

/// Parse a `transform` attribute into a single matrix. Unknown functions and
/// functions with too few arguments are skipped.
Matrix parseTransform(const(char)[] s)
{
    Matrix m;
    size_t i = 0;
    immutable n = s.length;
    while (i < n)
    {
        skipSeparators(s, i);
        size_t j = i;
        while (j < n && s[j] != '(' && !isWhite(s[j]) && s[j] != ',' && s[j] != ')')
            ++j;
        const name = s[i .. j];
        i = j;
        skipSpace(s, i);
        if (i >= n || s[i] != '(')
        {
            if (j == i && i < n && name.length == 0)
                ++i; // stray character
            continue;
        }
        ++i;
        immutable close = s[i .. $].indexOf(')');
        immutable end = close < 0 ? n : i + close;
        const a = parseNumberList(s[i .. end]);
        i = close < 0 ? n : end + 1;
        m = m * transformFunction(name, a);
    }
    return m;
}

private Matrix transformFunction(const(char)[] name, const double[] a)
{
    switch (name)
    {
    case "matrix":
        if (a.length >= 6)
            return Matrix(a[0], a[1], a[2], a[3], a[4], a[5]);
        break;
    case "translate":
        if (a.length >= 1)
            return Matrix.translation(a[0], a.length >= 2 ? a[1] : 0);
        break;
    case "scale":
        if (a.length >= 1)
            return Matrix.scaling(a[0], a.length >= 2 ? a[1] : a[0]);
        break;
    case "rotate":
        if (a.length >= 1)
        {
            immutable r = a[0] * PI / 180;
            immutable rot = Matrix(cos(r), sin(r), -sin(r), cos(r), 0, 0);
            if (a.length >= 3)
                return Matrix.translation(a[1], a[2]) * rot * Matrix.translation(-a[1], -a[2]);
            return rot;
        }
        break;
    case "skewX":
        if (a.length >= 1)
            return Matrix(1, 0, tan(a[0] * PI / 180), 1, 0, 0);
        break;
    case "skewY":
        if (a.length >= 1)
            return Matrix(1, tan(a[0] * PI / 180), 0, 1, 0, 0);
        break;
    default:
        break;
    }
    return Matrix.identity;
}

/// Parse a `style` attribute into a property map. Names are lower-cased and
/// trimmed; declarations without a `:` or with an empty value are dropped.
/// Later declarations of the same property replace earlier ones.
string[string] parseStyle(const(char)[] s)
{
    string[string] r;
    size_t start = 0;
    while (start <= s.length)
    {
        auto semi = s[start .. $].indexOf(';');
        immutable end = semi < 0 ? s.length : start + semi;
        auto decl = s[start .. end];
        immutable colon = decl.indexOf(':');
        if (colon >= 0)
        {
            immutable name = lowerCase(strip(decl[0 .. colon]));
            immutable value = strip(decl[colon + 1 .. $]).idup;
            if (name.length && value.length)
                r[name] = value;
        }
        start = end + 1;
    }
    return r;
}

unittest
{
    import std.math : isClose;

    double v;
    size_t i;
    foreach (t; ["5", ".5", "5.", "+5.25", "-1e2", "1E+2"])
    {
        i = 0;
        assert(scanNumber(t, i, v) && i == t.length, t);
    }
    i = 0;
    assert(scanNumber("1e", i, v) && i == 1 && v == 1);
    i = 0;
    assert(scanNumber("1.5.5", i, v) && i == 3 && v == 1.5);
    i = 0;
    assert(!scanNumber("-", i, v) && !scanNumber(".", i, v));
    assert(parseNumberExact(" 5. ", v) && v == 5);
    assert(parseLength("12px", v) && v == 12);
    assert(!parseLength("px", v));
    assert(parseNumberList("1,2 -3e1,.5x") == [1, 2, -30, 0.5]);
}

unittest
{
    double o = 1;
    assert(parseOpacity("50%", o) && o == 0.5);
    assert(parseOpacity(" 2 ", o) && o == 1);
    o = 0.3;
    assert(!parseOpacity("0.5px", o) && o == 0.3);
    assert(!parseOpacity("", o));
}

unittest
{
    ParsedColor c;
    assert(parseColor("#f39", c) && c.rgb == Rgb(0xff, 0x33, 0x99));
    assert(parseColor("#AbCdEf", c) && c.rgb == Rgb(0xab, 0xcd, 0xef));
    assert(parseColor("rgb(300, -5, 127.5)", c) && c.rgb == Rgb(255, 0, 128));
    assert(parseColor("rgb(100% 50% 0%)", c) && c.rgb == Rgb(255, 128, 0));
    assert(parseColor("CurrentColor", c) && c.current);
    assert(parseColor("NONE", c) && c.none);
    assert(parseColor("  Navy ", c) && c.rgb == Rgb(0, 0, 128));
    assert(!parseColor("#ff", c) && !parseColor("bogus", c));
}

unittest
{
    import std.math : isClose;

    immutable m = parseTransform("translate(10 20) scale(2)");
    immutable p = m.apply(Point(1, 1));
    assert(isClose(p.x, 12) && isClose(p.y, 22));
    immutable r = parseTransform("rotate(90, 5, 5)").apply(Point(6, 5));
    assert(isClose(r.x, 5, 1e-9, 1e-9) && isClose(r.y, 6));
    assert(parseTransform("bogus(1) scale()") == Matrix.identity);
    assert(parseTransform("matrix(1,2,3,4,5,6)").e == 5);
}

unittest
{
    auto st = parseStyle("fill : red;;stroke:blue; junk ; Opacity:.5;fill:");
    assert(st["opacity"] == ".5" && st["stroke"] == "blue");
    assert(st["fill"] == "red" && st.length == 3);
}

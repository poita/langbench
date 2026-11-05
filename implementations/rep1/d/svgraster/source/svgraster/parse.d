/// Parsers for the small value grammars used by SVG attributes: numbers,
/// lengths, opacities, colours, transform lists and `style` declarations.
module svgraster.parse;

import std.math : floor;
import svgraster.buf;
import svgraster.colors;
import svgraster.geom;

/// True for the XML/CSS whitespace characters.
bool isSpace(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

/// Advance `pos` past whitespace.
void skipSpace(const(char)[] s, ref size_t pos) pure nothrow @nogc @safe
{
    while (pos < s.length && isSpace(s[pos]))
        ++pos;
}

/// Advance `pos` past whitespace and commas.
void skipSpaceComma(const(char)[] s, ref size_t pos) pure nothrow @nogc @safe
{
    while (pos < s.length && (isSpace(s[pos]) || s[pos] == ','))
        ++pos;
}

/// `s` without leading and trailing whitespace.
inout(char)[] trim(inout(char)[] s) pure nothrow @nogc @safe
{
    size_t a = 0, b = s.length;
    while (a < b && isSpace(s[a]))
        ++a;
    while (b > a && isSpace(s[b - 1]))
        --b;
    return s[a .. b];
}

private bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

/// True if `c` can begin a number.
bool isNumberStart(char c) pure nothrow @nogc @safe
{
    return isDigit(c) || c == '.' || c == '+' || c == '-';
}

private double pow10(int n) pure nothrow @nogc @safe
{
    // n >= 0. Repeated squaring keeps small powers exact.
    double r = 1, b = 10;
    while (n > 0)
    {
        if (n & 1)
            r *= b;
        b *= b;
        n >>= 1;
    }
    return r;
}

/// Parse a number at `pos` (SPEC §4): sign, digits with optional fraction,
/// optional exponent. On success advances `pos` and stores the value; on
/// failure leaves `pos` unchanged.
bool parseNumber(const(char)[] s, ref size_t pos, out double value) pure nothrow @nogc @safe
{
    immutable n = s.length;
    size_t p = pos;
    bool neg = false;
    if (p < n && (s[p] == '+' || s[p] == '-'))
    {
        neg = s[p] == '-';
        ++p;
    }
    ulong mant = 0;
    int exp10 = 0;
    bool any = false;
    enum ulong limit = 1_000_000_000_000_000_000UL;
    while (p < n && isDigit(s[p]))
    {
        any = true;
        if (mant < limit)
            mant = mant * 10 + (s[p] - '0');
        else
            ++exp10;
        ++p;
    }
    if (p < n && s[p] == '.')
    {
        size_t q = p + 1;
        bool frac = false;
        while (q < n && isDigit(s[q]))
        {
            frac = true;
            if (mant < limit)
            {
                mant = mant * 10 + (s[q] - '0');
                --exp10;
            }
            ++q;
        }
        if (any || frac)
        {
            any = true;
            p = q;
        }
    }
    if (!any)
        return false;
    if (p < n && (s[p] == 'e' || s[p] == 'E'))
    {
        size_t q = p + 1;
        bool eneg = false;
        if (q < n && (s[q] == '+' || s[q] == '-'))
        {
            eneg = s[q] == '-';
            ++q;
        }
        if (q < n && isDigit(s[q]))
        {
            int e = 0;
            while (q < n && isDigit(s[q]))
            {
                if (e < 100_000)
                    e = e * 10 + (s[q] - '0');
                ++q;
            }
            exp10 += eneg ? -e : e;
            p = q;
        }
    }
    double v = cast(double) mant;
    if (mant != 0)
    {
        if (exp10 < 0)
        {
            int e = -exp10;
            if (e > 330)
                v = 0;
            else if (e > 300)
                v = v / pow10(300) / pow10(e - 300);
            else
                v = v / pow10(e);
        }
        else if (exp10 > 0)
        {
            v = exp10 > 330 ? double.infinity : v * pow10(exp10);
        }
    }
    value = neg ? -v : v;
    pos = p;
    return true;
}

/// Parse a length: a number optionally followed by `px`. Only the leading
/// number matters; anything after it is ignored. Returns false when `s` does
/// not start (after whitespace) with a number.
bool parseLength(const(char)[] s, out double value) pure nothrow @nogc @safe
{
    size_t p = 0;
    skipSpace(s, p);
    return parseNumber(s, p, value);
}

/// Parse an opacity: a number or a percentage, clamped to [0, 1]. Returns
/// false for anything else.
bool parseOpacity(const(char)[] s, out double value) pure nothrow @nogc @safe
{
    s = trim(s);
    size_t p = 0;
    double v;
    if (!parseNumber(s, p, v))
        return false;
    if (p < s.length && s[p] == '%')
    {
        v /= 100.0;
        ++p;
    }
    if (p != s.length)
        return false;
    value = v < 0 ? 0 : (v > 1 ? 1 : v);
    return true;
}

/// Parse all numbers in a list separated by whitespace and/or commas into
/// `out_`; stops at the first token that is not a number.
void parseNumberList(const(char)[] s, ref Buf!double out_) pure nothrow @safe
{
    size_t p = 0;
    for (;;)
    {
        skipSpaceComma(s, p);
        double v;
        if (p >= s.length || !parseNumber(s, p, v))
            return;
        out_.push(v);
    }
}

/// Kinds of paint a colour-valued property can take.
enum PaintKind : ubyte
{
    none,
    currentColor,
    color,
}

/// A parsed colour-valued property: `none`, `currentColor`, or an sRGB
/// colour with channels in [0, 1].
struct Paint
{
    PaintKind kind = PaintKind.none;
    double r = 0, g = 0, b = 0;

    /// The paint `none`.
    static Paint none() pure nothrow @nogc @safe { return Paint(PaintKind.none); }
    /// The marker `currentColor`.
    static Paint current() pure nothrow @nogc @safe { return Paint(PaintKind.currentColor); }
    /// An opaque colour from 8-bit channels.
    static Paint rgb8(uint r8, uint g8, uint b8) pure nothrow @nogc @safe
    {
        return Paint(PaintKind.color, r8 / 255.0, g8 / 255.0, b8 / 255.0);
    }
}

private int hexVal(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private char lower(char c) pure nothrow @nogc @safe
{
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

/// Case-insensitive (ASCII) equality with a lower-case literal.
bool equalsIgnoreCase(const(char)[] s, string lowerLit) pure nothrow @nogc @safe
{
    if (s.length != lowerLit.length)
        return false;
    foreach (i; 0 .. s.length)
        if (lower(s[i]) != lowerLit[i])
            return false;
    return true;
}

private uint roundHalfUp(double v) pure nothrow @nogc @safe
{
    return cast(uint) floor(v + 0.5);
}

/// Parse a paint: `none`, `currentColor`, `#rgb`, `#rrggbb`, `rgb(...)` or a
/// colour keyword. Returns false if `s` is none of these.
bool parsePaint(const(char)[] s, out Paint paint) pure nothrow @nogc @safe
{
    s = trim(s);
    if (s.length == 0)
        return false;
    if (equalsIgnoreCase(s, "none"))
    {
        paint = Paint.none;
        return true;
    }
    if (equalsIgnoreCase(s, "currentcolor"))
    {
        paint = Paint.current;
        return true;
    }
    if (s[0] == '#')
    {
        auto h = s[1 .. $];
        int[6] d;
        foreach (i, c; h)
        {
            if (i >= 6)
                return false;
            d[i] = hexVal(c);
            if (d[i] < 0)
                return false;
        }
        if (h.length == 3)
        {
            paint = Paint.rgb8(d[0] * 17, d[1] * 17, d[2] * 17);
            return true;
        }
        if (h.length == 6)
        {
            paint = Paint.rgb8(d[0] * 16 + d[1], d[2] * 16 + d[3], d[4] * 16 + d[5]);
            return true;
        }
        return false;
    }
    if (s.length > 4 && lower(s[0]) == 'r' && lower(s[1]) == 'g' && lower(s[2]) == 'b' && s[3] == '(')
    {
        size_t p = 4;
        uint[3] comp;
        foreach (i; 0 .. 3)
        {
            skipSpaceComma(s, p);
            double v;
            if (!parseNumber(s, p, v))
                return false;
            if (p < s.length && s[p] == '%')
            {
                ++p;
                v = v < 0 ? 0 : (v > 100 ? 100 : v);
                v = v * 255.0 / 100.0;
            }
            else
                v = v < 0 ? 0 : (v > 255 ? 255 : v);
            comp[i] = roundHalfUp(v);
        }
        skipSpaceComma(s, p);
        if (p >= s.length || s[p] != ')')
            return false;
        paint = Paint.rgb8(comp[0], comp[1], comp[2]);
        return true;
    }
    if (s.length > 24)
        return false;
    char[24] buf;
    foreach (i, c; s)
        buf[i] = lower(c);
    uint rgb;
    if (lookupColor(buf[0 .. s.length], rgb))
    {
        paint = Paint.rgb8((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
        return true;
    }
    return false;
}

/// Parse a `transform` attribute (SPEC §7.2) into one matrix. Unknown
/// functions and functions with too few arguments are skipped.
Matrix parseTransform(const(char)[] s) pure nothrow @safe
{
    import std.math : isNaN;

    Matrix m;
    size_t p = 0;
    Buf!double args;
    for (;;)
    {
        skipSpaceComma(s, p);
        size_t a = p;
        while (p < s.length && ((s[p] >= 'a' && s[p] <= 'z') || (s[p] >= 'A' && s[p] <= 'Z')))
            ++p;
        if (p == a)
            break;
        auto name = s[a .. p];
        skipSpace(s, p);
        if (p >= s.length || s[p] != '(')
            break;
        ++p;
        args.clear();
        for (;;)
        {
            skipSpaceComma(s, p);
            double v;
            if (!parseNumber(s, p, v))
                break;
            args.push(v);
        }
        skipSpace(s, p);
        if (p >= s.length || s[p] != ')')
            break;
        ++p;
        auto v = args.slice;
        if (name == "matrix")
        {
            if (v.length >= 6)
                m = m * Matrix(v[0], v[1], v[2], v[3], v[4], v[5]);
        }
        else if (name == "translate")
        {
            if (v.length >= 1)
                m = m * Matrix.translate(v[0], v.length >= 2 ? v[1] : 0);
        }
        else if (name == "scale")
        {
            if (v.length >= 1)
                m = m * Matrix.scale(v[0], v.length >= 2 ? v[1] : v[0]);
        }
        else if (name == "rotate")
        {
            if (v.length >= 3)
                m = m * Matrix.translate(v[1], v[2]) * Matrix.rotate(v[0]) * Matrix.translate(-v[1], -v[2]);
            else if (v.length >= 1)
                m = m * Matrix.rotate(v[0]);
        }
        else if (name == "skewX")
        {
            if (v.length >= 1)
                m = m * Matrix.skewX(v[0]);
        }
        else if (name == "skewY")
        {
            if (v.length >= 1)
                m = m * Matrix.skewY(v[0]);
        }
    }
    return m;
}

/// One `name: value` declaration from a `style` attribute (both trimmed, not
/// lower-cased; compare names with `equalsIgnoreCase`).
struct Decl
{
    const(char)[] name;
    const(char)[] value;
}

/// Split a `style` attribute into declarations, appending to `out_`. Empty
/// declarations, declarations without `:` and declarations with an empty
/// value are dropped.
void parseStyle(const(char)[] s, ref Buf!Decl out_) pure nothrow @safe
{
    size_t i = 0;
    while (i <= s.length)
    {
        size_t j = i;
        while (j < s.length && s[j] != ';')
            ++j;
        auto d = s[i .. j];
        size_t colon = 0;
        while (colon < d.length && d[colon] != ':')
            ++colon;
        if (colon < d.length)
        {
            auto name = trim(d[0 .. colon]);
            auto value = trim(d[colon + 1 .. $]);
            if (name.length && value.length)
                out_.push(Decl(name, value));
        }
        i = j + 1;
    }
}

/// Font metric (`.cfm`) loading and the nine-face table.
module typeset.fonts;

import std.file : readText;
import std.path : buildPath;
import typeset.arith : scale;
import typeset.values : decodeAt;

/// A font family selector.
enum Family : ubyte
{
    serif,
    sans,
    mono,
}

/// Number of faces.
enum faceCount = 9;

/// Index of the monospaced face.
enum monoFace = 8;

/// Marker for "no face" (rigid boxes).
enum noFace = ubyte.max;

/// Face names in index order.
immutable string[faceCount] faceNames = [
    "serif", "serif-bold", "serif-italic", "serif-bold-italic",
    "sans", "sans-bold", "sans-italic", "sans-bold-italic", "mono",
];

/// The face index of a (family, bold, italic) style.
ubyte faceIndex(Family f, bool bold, bool italic) pure nothrow @nogc @safe
{
    if (f == Family.mono)
        return monoFace;
    return cast(ubyte)(f * 4 + (bold ? 1 : 0) + (italic ? 2 : 0));
}

/// Parsed metrics of one face. Advances and kerns are in 1/1000 em.
struct Face
{
    string name; ///
    int ascent; ///
    int descent; ///
    int space; /// natural inter-word glue
    int stretch; ///
    int shrink; ///
    int extra; /// added after a sentence-ending period
    int defaultAdv; /// advance of a code point with no `glyph` record
    int[] advances; /// dense advance table indexed by code point
    int[ulong] kerns; /// packed `(a << 32) | b` -> kern
    bool[] kernFirst; /// dense table: does this code point start any kern pair?

    /// Advance of code point `c` in glyph units.
    int adv(uint c) const pure nothrow @nogc @safe
    {
        return c < advances.length ? advances[c] : defaultAdv;
    }

    /// Kern of the ordered pair `(a, b)` in glyph units.
    int kern(uint a, uint b) const pure nothrow @safe
    {
        if (a >= kernFirst.length || !kernFirst[a])
            return 0;
        if (auto p = ((cast(ulong) a << 32) | b) in kerns)
            return *p;
        return 0;
    }

    /// Width in glyph units of a sequence of code points, kerns included.
    long units(const(uint)[] cps) const pure nothrow @safe
    {
        long u;
        foreach (i, c; cps)
        {
            u += adv(c);
            if (i + 1 < cps.length)
                u += kern(c, cps[i + 1]);
        }
        return u;
    }

    /// Width in millipoints of a box holding `cps` at `size`.
    long width(const(uint)[] cps, long size) const pure nothrow @safe
    {
        return scale(units(cps), size);
    }
}

/// Splits a metric/pattern line into fields after stripping `#` comments.
string[] fieldsOf(const(char)[] line) pure @safe
{
    foreach (i, c; line)
        if (c == '#')
        {
            line = line[0 .. i];
            break;
        }
    string[] r;
    size_t i;
    while (i < line.length)
    {
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            ++i;
        size_t s = i;
        while (i < line.length && line[i] != ' ' && line[i] != '\t')
            ++i;
        if (i > s)
            r ~= line[s .. i].idup;
    }
    return r;
}

private int toInt(string s) pure @safe
{
    import std.conv : to;

    return s.to!int;
}

/// Parses the text of a `.cfm` file.
Face parseFace(const(char)[] text) @safe
{
    import typeset.values : splitLines;

    Face f;
    int[uint] glyphs;
    uint maxCp;
    struct K
    {
        uint a, b;
        int v;
    }

    K[] kernList;
    foreach (line; splitLines(text))
    {
        auto fs = fieldsOf(line);
        if (fs.length == 0)
            continue;
        switch (fs[0])
        {
        case "face":
            f.name = fs[1];
            break;
        case "ascent":
            f.ascent = toInt(fs[1]);
            break;
        case "descent":
            f.descent = toInt(fs[1]);
            break;
        case "space":
            f.space = toInt(fs[1]);
            f.stretch = toInt(fs[2]);
            f.shrink = toInt(fs[3]);
            break;
        case "extra":
            f.extra = toInt(fs[1]);
            break;
        case "default":
            f.defaultAdv = toInt(fs[1]);
            break;
        case "glyph":
            immutable cp = cast(uint) toInt(fs[1]);
            glyphs[cp] = toInt(fs[2]);
            if (cp > maxCp)
                maxCp = cp;
            break;
        case "kern":
            kernList ~= K(cast(uint) toInt(fs[1]), cast(uint) toInt(fs[2]), toInt(fs[3]));
            break;
        default:
            break;
        }
    }
    // A dense table up to the largest listed code point; anything beyond uses `default`.
    f.advances = new int[maxCp + 1];
    f.advances[] = f.defaultAdv;
    foreach (cp, a; glyphs)
        f.advances[cp] = a;
    uint maxFirst;
    foreach (k; kernList)
        if (k.a > maxFirst)
            maxFirst = k.a;
    f.kernFirst = new bool[kernList.length ? maxFirst + 1 : 0];
    foreach (k; kernList)
    {
        f.kerns[(cast(ulong) k.a << 32) | k.b] = k.v;
        f.kernFirst[k.a] = true;
    }
    return f;
}

/// The nine faces.
final class FontSet
{
    Face[faceCount] faces; ///

    /// Loads `<dataDir>/faces/<face>.cfm` for every face.
    static FontSet load(string dataDir)
    {
        auto fs = new FontSet;
        foreach (i, n; faceNames)
            fs.faces[i] = parseFace(readText(buildPath(dataDir, "faces", n ~ ".cfm")));
        return fs;
    }

    /// Builds a set from in-memory `.cfm` texts (one per face, in index order).
    static FontSet fromTexts(const(string)[] texts)
    {
        auto fs = new FontSet;
        foreach (i; 0 .. faceCount)
            fs.faces[i] = parseFace(texts[i < texts.length ? i : texts.length - 1]);
        return fs;
    }

    /// Face accessor.
    ref const(Face) opIndex(size_t i) const pure nothrow @nogc @safe
    {
        return faces[i];
    }
}

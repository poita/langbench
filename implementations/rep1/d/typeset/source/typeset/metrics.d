/**
 * Font metric files (`.cfm`) and the nine faces.
 *
 * A face supplies glyph advances, a kerning table and the vertical metrics
 * and inter-word glue of one style. All values are in thousandths of an em;
 * use $(REF scale, typeset,units) to convert to millipoints.
 */
module typeset.metrics;

import std.conv : to;
import std.file : readText;
import std.path : buildPath;
import std.string : indexOf, strip, splitLines;

import typeset.units;

/// Font family of a style.
enum Family : ubyte
{
    serif,
    sans,
    mono
}

/// Number of faces shipped with the engine.
enum faceCount = 9;

/// Face names in index order.
immutable string[faceCount] faceNames = [
    "serif", "serif-bold", "serif-italic", "serif-bold-italic",
    "sans", "sans-bold", "sans-italic", "sans-bold-italic", "mono"
];

/// Index into the face table for a (family, bold, italic) style.
ubyte faceIndex(Family family, bool bold, bool italic) pure nothrow @safe @nogc
{
    if (family == Family.mono)
        return 8;
    return cast(ubyte)(family * 4 + (bold ? 1 : 0) + (italic ? 2 : 0));
}

@safe pure nothrow @nogc unittest
{
    assert(faceIndex(Family.serif, false, false) == 0);
    assert(faceIndex(Family.serif, true, true) == 3);
    assert(faceIndex(Family.sans, true, false) == 5);
    assert(faceIndex(Family.mono, true, true) == 8);
}

/// The metrics of one face.
struct Face
{
    string name;
    long ascent, descent;
    long space, stretch, shrink;
    long extra;
    long defaultAdvance;
    private int[128] ascii = -1; // -1: no glyph record
    private int[dchar] glyphs;
    private int[ulong] kerns;

    /// Advance of a code point, in 1/1000 em.
    long adv(dchar c) const pure nothrow @safe
    {
        if (c < 128)
        {
            immutable v = ascii[c];
            return v >= 0 ? v : defaultAdvance;
        }
        if (auto p = c in glyphs)
            return *p;
        return defaultAdvance;
    }

    /// Kern between an ordered pair, in 1/1000 em (0 when absent).
    long kern(dchar a, dchar b) const pure nothrow @safe
    {
        if (kerns.length == 0)
            return 0;
        if (auto p = ((cast(ulong) a << 32) | b) in kerns)
            return *p;
        return 0;
    }

    /// Glyph-space width of a string: advances plus kerns of adjacent pairs.
    long units(const(dchar)[] text) const pure nothrow @safe
    {
        long u = 0;
        foreach (i, c; text)
        {
            u += adv(c);
            if (i + 1 < text.length)
                u += kern(c, text[i + 1]);
        }
        return u;
    }

    /// Width in millipoints of `text` set at `size` (one `scale` of the total).
    long width(const(dchar)[] text, long size) const pure nothrow @safe
    {
        return scale(units(text), size);
    }

    /// Parses the text of a `.cfm` file.
    static Face parse(string source)
    {
        Face f;
        foreach (raw; source.splitLines)
        {
            string line = raw;
            immutable h = line.indexOf('#');
            if (h >= 0)
                line = line[0 .. h];
            line = line.strip(" \t");
            if (line.length == 0)
                continue;
            auto fields = splitFields(line);
            switch (fields[0])
            {
            case "face":
                f.name = fields[1];
                break;
            case "ascent":
                f.ascent = fields[1].to!long;
                break;
            case "descent":
                f.descent = fields[1].to!long;
                break;
            case "space":
                f.space = fields[1].to!long;
                f.stretch = fields[2].to!long;
                f.shrink = fields[3].to!long;
                break;
            case "extra":
                f.extra = fields[1].to!long;
                break;
            case "default":
                f.defaultAdvance = fields[1].to!long;
                break;
            case "glyph":
                {
                    immutable cp = cast(dchar) fields[1].to!uint;
                    immutable a = fields[2].to!int;
                    if (cp < 128)
                        f.ascii[cp] = a;
                    else
                        f.glyphs[cp] = a;
                    break;
                }
            case "kern":
                {
                    immutable a = cast(dchar) fields[1].to!uint;
                    immutable b = cast(dchar) fields[2].to!uint;
                    f.kerns[(cast(ulong) a << 32) | b] = fields[3].to!int;
                    break;
                }
            default:
                break; // "cfm" version record and unknown records
            }
        }
        return f;
    }
}

package string[] splitFields(string line) pure @safe
{
    string[] r;
    size_t start = size_t.max;
    foreach (i, c; line)
    {
        immutable ws = c == ' ' || c == '\t';
        if (ws && start != size_t.max)
        {
            r ~= line[start .. i];
            start = size_t.max;
        }
        else if (!ws && start == size_t.max)
            start = i;
    }
    if (start != size_t.max)
        r ~= line[start .. $];
    return r;
}

/// The nine faces, indexed by $(LREF faceIndex).
final class FaceSet
{
    Face[faceCount] faces;

    /// Loads `<dataDir>/faces/<face>.cfm` for all nine faces.
    static FaceSet load(string dataDir)
    {
        auto set = new FaceSet;
        foreach (i, name; faceNames)
            set.faces[i] = Face.parse(readText(buildPath(dataDir, "faces", name ~ ".cfm")));
        return set;
    }

    /// Builds a set from in-memory `.cfm` texts (in $(LREF faceNames) order).
    static FaceSet fromSources(const string[faceCount] sources)
    {
        auto set = new FaceSet;
        foreach (i, s; sources)
            set.faces[i] = Face.parse(s);
        return set;
    }

    ref const(Face) opIndex(size_t i) const pure nothrow @safe @nogc
    {
        return faces[i];
    }
}

unittest
{
    immutable src = "cfm 1\nface x # c\nascent 700\ndescent 200\nspace 250 125 80\nextra 100\ndefault 500\n"
        ~ "glyph 65 600\nglyph 66 700\nglyph 8226 344\nkern 65 66 -50\n";
    auto f = Face.parse(src);
    assert(f.name == "x" && f.ascent == 700 && f.stretch == 125);
    assert(f.adv('A') == 600 && f.adv('Z') == 500 && f.adv('•') == 344);
    assert(f.units("AB"d) == 600 + 700 - 50);
    assert(f.width("AB"d, 10_000) == 12_500);
    assert(f.width(""d, 10_000) == 0);
}

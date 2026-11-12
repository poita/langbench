/**
 * Liang hyphenation patterns (`.chp` files) and the hyphenation algorithm.
 */
module typeset.hyphenation;

import std.conv : to;
import std.file : readText;
import std.path : buildPath;
import std.string : indexOf, strip, splitLines;

import typeset.metrics : splitFields;

/// Which pattern set is active.
enum PatternId : ubyte
{
    english,
    minimal
}

/// A pattern set: Liang patterns, exceptions and the left/right minima.
final class PatternSet
{
    /// Minimum number of letters before the first and after the last break.
    int left = 1, right = 1;

    private int[][string] patterns; // key (letters and '.') -> values, length key+1
    private int[][string] exceptions; // word -> break positions
    private size_t maxKey;
    private int[][string] cache;

    /// Parses the text of a `.chp` file.
    static PatternSet parse(string source)
    {
        auto set = new PatternSet;
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
            case "left":
                set.left = fields[1].to!int;
                break;
            case "right":
                set.right = fields[1].to!int;
                break;
            case "pattern":
                set.addPattern(fields[1]);
                break;
            case "exception":
                set.addException(fields[1]);
                break;
            default:
                break;
            }
        }
        return set;
    }

    /// Loads `<dataDir>/hyphen/<id>.chp`.
    static PatternSet load(string dataDir, PatternId id)
    {
        return parse(readText(buildPath(dataDir, "hyphen", id.to!string ~ ".chp")));
    }

    private void addPattern(string text)
    {
        string key;
        int[] values = [0];
        foreach (c; text)
        {
            if (c >= '0' && c <= '9')
                values[$ - 1] = c - '0';
            else
            {
                key ~= c;
                values ~= 0;
            }
        }
        patterns[key] = values;
        if (key.length > maxKey)
            maxKey = key.length;
    }

    private void addException(string text)
    {
        string word;
        int[] positions;
        foreach (c; text)
        {
            if (c == '-')
                positions ~= cast(int) word.length;
            else
                word ~= c;
        }
        exceptions[word] = positions;
    }

    /// Break positions `q` (break after `q` letters) for a lowercase,
    /// letters-only word, after the left/right minima.
    const(int)[] breaks(string word)
    {
        if (auto c = word in cache)
            return *c;
        auto r = compute(word);
        cache[word] = r;
        return r;
    }

    private int[] compute(string s)
    {
        immutable n = cast(int) s.length;
        int[] result;
        if (auto e = s in exceptions)
        {
            foreach (q; *e)
                if (q >= left && q <= n - right && q >= 1 && q <= n - 1)
                    result ~= q;
            return result;
        }
        string t = "." ~ s ~ ".";
        auto v = new int[n + 3];
        foreach (i; 0 .. n + 2)
        {
            immutable jmax = (i + maxKey < n + 2) ? i + maxKey : n + 2;
            foreach (j; i + 1 .. jmax + 1)
            {
                if (auto p = t[i .. j] in patterns)
                {
                    foreach (k, val; *p)
                        if (val > v[i + k])
                            v[i + k] = val;
                }
            }
        }
        foreach (q; 1 .. n)
        {
            if ((v[1 + q] & 1) && q >= left && q <= n - right)
                result ~= q;
        }
        return result;
    }
}

/// Letter test used throughout hyphenation: `A-Z` or `a-z`.
bool isLetter(dchar c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

unittest
{
    immutable src = "chp 1\nleft 2\nright 3\npattern n1t\npattern t1t\npattern 3ing\npattern n1g\n"
        ~ "pattern .win1\nexception al-go-rithm\n";
    auto p = PatternSet.parse(src);
    assert(p.breaks("winter") == [3]);
    assert(p.breaks("typesetting") == [7, 8]);
    assert(p.breaks("algorithm") == [2, 4]);
    assert(p.breaks("ab") == []);
}

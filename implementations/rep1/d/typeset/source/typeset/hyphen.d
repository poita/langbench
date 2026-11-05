/// Liang hyphenation pattern sets (`.chp` files) and the hyphenator.
module typeset.hyphen;

import std.file : readText;
import std.path : buildPath;
import typeset.fonts : fieldsOf;
import typeset.values : splitLines;

/// The two supplied pattern sets.
enum PatternsId : ubyte
{
    english,
    minimal,
}

/// Name of a pattern set file (without extension).
string patternsName(PatternsId id) pure nothrow @nogc @safe
{
    return id == PatternsId.english ? "english" : "minimal";
}

/// A Liang pattern set with its minima and exceptions, plus a memo table so
/// that each distinct word is hyphenated once.
final class PatternSet
{
    int left = 1; /// minimum letters before the first break
    int right = 1; /// minimum letters after the last break

    private
    {
        // Trie over 27 symbols: 'a'..'z' -> 0..25 and '.' -> 26.
        int[] child;
        int[] valueOffset;
        ubyte[] values;
        int[][string] exceptions;
        int[][string] memo;
    }

    private static int symbol(char c) pure nothrow @nogc @safe
    {
        return c == '.' ? 26 : c - 'a';
    }

    this()
    {
        child = new int[27];
        valueOffset = [-1];
    }

    /// Adds a pattern such as `.anti3` or `c2h`.
    void addPattern(const(char)[] pattern)
    {
        char[] key;
        ubyte[] vals;
        ubyte pending;
        foreach (c; pattern)
        {
            if (c >= '0' && c <= '9')
                pending = cast(ubyte)(c - '0');
            else
            {
                key ~= c;
                vals ~= pending;
                pending = 0;
            }
        }
        vals ~= pending;
        int node;
        foreach (c; key)
        {
            immutable s = symbol(c);
            if (child[node * 27 + s] == 0)
            {
                child[node * 27 + s] = cast(int) valueOffset.length;
                valueOffset ~= -1;
                child.length += 27;
            }
            node = child[node * 27 + s];
        }
        valueOffset[node] = cast(int) values.length;
        values ~= vals;
    }

    /// Adds an exception such as `al-go-rithm`.
    void addException(const(char)[] word)
    {
        char[] plain;
        int[] pos;
        foreach (c; word)
        {
            if (c == '-')
                pos ~= cast(int) plain.length;
            else
                plain ~= c;
        }
        exceptions[plain.idup] = pos;
    }

    /// Parses the text of a `.chp` file.
    static PatternSet parse(const(char)[] text)
    {
        import std.conv : to;

        auto ps = new PatternSet;
        foreach (line; splitLines(text))
        {
            auto fs = fieldsOf(line);
            if (fs.length < 2)
                continue;
            switch (fs[0])
            {
            case "left":
                ps.left = fs[1].to!int;
                break;
            case "right":
                ps.right = fs[1].to!int;
                break;
            case "pattern":
                ps.addPattern(fs[1]);
                break;
            case "exception":
                ps.addException(fs[1]);
                break;
            default:
                break;
            }
        }
        return ps;
    }

    /// Loads `<dataDir>/hyphen/<set>.chp`.
    static PatternSet load(string dataDir, PatternsId id)
    {
        return parse(readText(buildPath(dataDir, "hyphen", patternsName(id) ~ ".chp")));
    }

    /// Break positions (`q` letters before the break) of a lowercase
    /// all-letter segment, already filtered by the `left`/`right` minima.
    /// The result is memoised and must not be modified.
    const(int)[] hyphenate(const(char)[] word)
    {
        if (auto m = cast(string) word in memo)
            return *m;
        int[] result = compute(word);
        memo[word.idup] = result;
        return result;
    }

    private int[] compute(const(char)[] word)
    {
        immutable n = cast(int) word.length;
        int[] result;
        if (auto ex = cast(string) word in exceptions)
        {
            foreach (q; *ex)
                if (q >= left && q <= n - right)
                    result ~= q;
            return result;
        }
        if (n < 2)
            return result;
        // t = "." ~ word ~ "."; v has n + 3 entries.
        auto v = new ubyte[n + 3];
        ubyte[] t = new ubyte[n + 2];
        t[0] = 26;
        foreach (i, c; word)
            t[i + 1] = cast(ubyte)(c - 'a');
        t[n + 1] = 26;
        foreach (i; 0 .. n + 2)
        {
            int node;
            foreach (j; i .. n + 2)
            {
                node = child[node * 27 + t[j]];
                if (node == 0)
                    break;
                immutable off = valueOffset[node];
                if (off >= 0)
                {
                    immutable len = j + 1 - i;
                    foreach (k; 0 .. len + 1)
                        if (values[off + k] > v[i + k])
                            v[i + k] = values[off + k];
                }
            }
        }
        foreach (q; 1 .. n)
            if ((v[1 + q] & 1) && q >= left && q <= n - right)
                result ~= q;
        return result;
    }
}

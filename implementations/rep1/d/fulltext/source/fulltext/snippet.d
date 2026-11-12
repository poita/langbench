/**
 * Snippet selection: finds the best 30-token window of a document for a set
 * of atom occurrences and cuts it out of the original text.
 */
module fulltext.snippet;

import fulltext.analysis;

@safe:

/// Window size `W`, in tokens.
enum uint windowSize = 30;

/// The occurrences of one positive atom in one document.
struct AtomHits
{
    /// Number of terms in the atom.
    uint terms;
    /// Sorted start positions of the occurrences.
    const(uint)[] starts;
}

/**
 * Finds the start `s` of the best window in a document of `length` tokens.
 *
 * Windows cover token positions `s .. min(s + W, length) - 1`, with
 * `0 <= s <= max(0, length - W)`. The best window has, in this order, the most
 * distinct atoms with an occurrence inside it, the most occurrences inside it,
 * and the smallest `s`.
 *
 * Runs in O(length + total occurrences) using difference arrays: an
 * occurrence of `n` terms at `p` lies inside exactly the windows with
 * `max(0, p + n - W) <= s <= min(p, length - W)`.
 */
uint bestWindow(uint length, const(AtomHits)[] atoms) pure nothrow
{
    if (length <= windowSize)
        return 0;
    immutable smax = length - windowSize;
    auto distinct = new int[smax + 2];
    auto total = new int[smax + 2];

    foreach (ref atom; atoms)
    {
        if (atom.terms > windowSize)
            continue;
        bool open = false;
        uint curLo, curHi;
        foreach (p; atom.starts)
        {
            immutable end = p + atom.terms;
            immutable lo = end > windowSize ? end - windowSize : 0;
            immutable hi = p < smax ? p : smax;
            total[lo]++;
            total[hi + 1]--;
            if (open && lo <= curHi + 1)
            {
                if (hi > curHi)
                    curHi = hi;
            }
            else
            {
                if (open)
                {
                    distinct[curLo]++;
                    distinct[curHi + 1]--;
                }
                open = true;
                curLo = lo;
                curHi = hi;
            }
        }
        if (open)
        {
            distinct[curLo]++;
            distinct[curHi + 1]--;
        }
    }

    uint best = 0;
    int bestDistinct = -1, bestTotal = -1;
    int d = 0, t = 0;
    foreach (s; 0 .. smax + 1)
    {
        d += distinct[s];
        t += total[s];
        if (d > bestDistinct || (d == bestDistinct && t > bestTotal))
        {
            best = s;
            bestDistinct = d;
            bestTotal = t;
        }
    }
    return best;
}

/**
 * Cuts the window starting at token `start` out of `text` (a document of
 * `length` tokens): from the first character of the first token to the last
 * character of the last token, with every run of whitespace collapsed to a
 * single space. A document with no tokens gives an empty string.
 */
string extractWindow(string text, uint length, uint start) pure
{
    if (length == 0)
        return "";
    immutable last = (start + windowSize < length ? start + windowSize : length) - 1;
    size_t from = 0, to = 0;
    foreach (tok; tokenize(text))
    {
        if (tok.position == start)
            from = tok.begin;
        if (tok.position == last)
        {
            to = tok.end;
            break;
        }
    }
    return collapseSpace(text[from .. to]);
}

/// Replaces each maximal run of whitespace code points by one space.
string collapseSpace(string s) pure
{
    import std.array : appender;
    import std.utf : decode, encode;

    auto app = appender!string;
    app.reserve(s.length);
    bool inSpace = false;
    size_t i = 0;
    while (i < s.length)
    {
        immutable begin = i;
        immutable c = decode(s, i);
        if (isSpace(c))
        {
            if (!inSpace)
                app.put(' ');
            inSpace = true;
        }
        else
        {
            inSpace = false;
            app.put(s[begin .. i]);
        }
    }
    return app.data;
}

/// Convenience: the snippet of a document for the given atom occurrences.
string makeSnippet(string text, uint length, const(AtomHits)[] atoms) pure
{
    return extractWindow(text, length, bestWindow(length, atoms));
}

unittest
{
    assert(collapseSpace("a \n\t b  c") == "a b c");
    assert(collapseSpace("") == "");
    assert(collapseSpace("a b") == "a b");
}

unittest
{
    // short document: always window 0
    assert(bestWindow(10, [AtomHits(1, [5])]) == 0);
    assert(bestWindow(0, []) == 0);
    // one occurrence late in a long document: earliest window containing it
    assert(bestWindow(100, [AtomHits(1, [50])]) == 21);
    // occurrence near the end: windows clipped to the last valid start
    assert(bestWindow(100, [AtomHits(1, [99])]) == 70);
    // no occurrences
    assert(bestWindow(100, []) == 0);
    // atom longer than the window never counts
    assert(bestWindow(100, [AtomHits(31, [40])]) == 0);
    // distinct atoms beat raw counts
    assert(bestWindow(100, [AtomHits(1, [0, 1, 2, 3]), AtomHits(1, [90])]) == 0);
    assert(bestWindow(100, [AtomHits(1, [0]), AtomHits(1, [40, 41]), AtomHits(1, [60])]) == 31);
}

unittest
{
    // brute-force comparison
    import std.random : Random, uniform;

    auto rng = Random(42);
    foreach (iter; 0 .. 300)
    {
        immutable L = uniform(0u, 90u, rng);
        AtomHits[] atoms;
        foreach (a; 0 .. uniform(0, 4, rng))
        {
            immutable n = uniform(1u, 35u, rng);
            uint[] starts;
            if (L >= n)
                foreach (p; 0 .. L - n + 1)
                    if (uniform(0, 8, rng) == 0)
                        starts ~= p;
            atoms ~= AtomHits(n, starts);
        }
        // brute force
        immutable smax = L > windowSize ? L - windowSize : 0;
        uint best = 0;
        int bd = -1, bt = -1;
        foreach (s; 0 .. smax + 1)
        {
            immutable e = (s + windowSize < L ? s + windowSize : L);
            int d, t;
            foreach (ref a; atoms)
            {
                int c;
                foreach (p; a.starts)
                    if (p >= s && p + a.terms <= e)
                        c++;
                if (c)
                    d++;
                t += c;
            }
            if (d > bd || (d == bd && t > bt))
            {
                best = s;
                bd = d;
                bt = t;
            }
        }
        assert(bestWindow(L, atoms) == best);
    }
}

unittest
{
    immutable text = "  Hello,\n  big   world! tail";
    assert(extractWindow(text, 4, 0) == "Hello, big world! tail");
    assert(extractWindow("...", 0, 0) == "");
    assert(makeSnippet("The quick brown fox", 4, [AtomHits(1, [1])]) == "The quick brown fox");

    // long: window of 30 tokens
    string t;
    foreach (i; 0 .. 40)
        t ~= "w" ~ cast(char)('a' + i % 26) ~ "\n";
    auto s = extractWindow(t, 40, 5);
    assert(s[0 .. 2] == "wf");
    import std.algorithm : count;
    assert(s.count(' ') == 29);
}

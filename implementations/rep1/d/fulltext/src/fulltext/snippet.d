/**
 * Snippet selection: the best 30-token window and its text.
 */
module fulltext.snippet;

import fulltext.whitespace : collapseSpace;

/// Window width in tokens.
enum uint windowWidth = 30;

/// The occurrences of one positive atom inside one document.
struct AtomHits
{
    /// Number of terms in the atom.
    uint length;
    /// Ascending start positions of its occurrences.
    const(uint)[] starts;
}

/**
 * Chooses the start `s` of the best window in a document of `docLength`
 * tokens: most distinct atoms inside, then most occurrences inside, then the
 * smallest `s`. Runs in O(L + occurrences) using difference arrays.
 */
uint bestWindowStart(size_t docLength, const(AtomHits)[] atoms, uint width = windowWidth) pure nothrow @safe
{
    if (docLength <= width)
        return 0;
    immutable last = cast(int)(docLength - width);
    auto total = new int[last + 2];
    auto distinct = new int[last + 2];
    bool any = false;
    foreach (ref a; atoms)
    {
        if (a.length > width)
            continue;
        int curLo = 0, curHi = -2; // current merged interval (empty)
        foreach (p; a.starts)
        {
            immutable lo = (cast(int) p + cast(int) a.length - cast(int) width) > 0
                ? cast(int) p + cast(int) a.length - cast(int) width : 0;
            immutable hi = (cast(int) p < last) ? cast(int) p : last;
            if (lo > hi)
                continue;
            any = true;
            total[lo] += 1;
            total[hi + 1] -= 1;
            if (lo <= curHi + 1 && curHi >= 0)
            {
                if (hi > curHi)
                    curHi = hi;
            }
            else
            {
                if (curHi >= 0)
                {
                    distinct[curLo] += 1;
                    distinct[curHi + 1] -= 1;
                }
                curLo = lo;
                curHi = hi;
            }
        }
        if (curHi >= 0)
        {
            distinct[curLo] += 1;
            distinct[curHi + 1] -= 1;
        }
    }
    if (!any)
        return 0;
    int bestD = -1, bestT = -1;
    uint bestS = 0;
    int d = 0, t = 0;
    foreach (s; 0 .. last + 1)
    {
        d += distinct[s];
        t += total[s];
        if (d > bestD || (d == bestD && t > bestT))
        {
            bestD = d;
            bestT = t;
            bestS = cast(uint) s;
        }
    }
    return bestS;
}

/**
 * Extracts the snippet text of the window starting at token `start`: the
 * original text from that token's first byte to the last byte of token
 * `min(start + width, L) - 1`, with whitespace runs collapsed to a space.
 */
string snippetText(const(ubyte)[] text, const(uint)[] tokenStarts, const(uint)[] tokenEnds,
        uint start, uint width = windowWidth) pure @safe
{
    immutable len = tokenStarts.length;
    if (len == 0)
        return "";
    immutable endTok = (start + width < len ? start + width : len) - 1;
    return collapseSpace(text[tokenStarts[start] .. tokenEnds[endTok]]);
}

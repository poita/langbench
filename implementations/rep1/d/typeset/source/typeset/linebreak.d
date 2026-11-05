/// Total-fit line breaking over the prefix sums of a horizontal list.
module typeset.linebreak;

import typeset.arith : LineKind, evaluateLine, Fitness;
import typeset.hlist;
import typeset.settings : Settings;

/// The outcome of breaking one horizontal list.
struct BreakResult
{
    int[] breaks; /// chosen breakpoints (item indices), ending with the final one
    long demerits; /// total demerits of the chosen breaking
    bool emergency; /// whether pass 2 was needed
}

private struct Node
{
    long total;
    long sW, sY, sZ; // prefix sums at the start of the node's following line
    int bp; // breakpoint item index (-1 for the start)
    int prev;
    int sI;
    ubyte cls;
    bool flagged;
}

/// Breaks horizontal lists. Scratch storage is reused between calls.
struct LineBreaker
{
    private Node[] nodes;
    private int[] active;
    private size_t activeLen;

    /// Breaks `h` with the measure and first-line indent from `h.ctx`
    /// (or the overrides given) using settings `s`.
    BreakResult breakList(const HList h, const ref Settings s)
    {
        BreakResult r;
        if (!runPass(h, s, false, r))
        {
            runPass(h, s, true, r);
            r.emergency = true;
        }
        return r;
    }

    private void addActive(int id)
    {
        if (activeLen == active.length)
            active.length = active.length ? active.length * 2 : 64;
        active[activeLen++] = id;
    }

    private void newNode(const HList h, long total, int bp, int cls, bool flagged, int prev)
    {
        Node n;
        n.total = total;
        n.bp = bp;
        n.cls = cast(ubyte) cls;
        n.flagged = flagged;
        n.prev = prev;
        immutable st = h.nextNonGlue[bp + 1];
        n.sW = h.cw[st];
        n.sY = h.cy[st];
        n.sZ = h.cz[st];
        n.sI = h.ci[st];
        nodes ~= n;
    }

    private bool runPass(const HList h, const ref Settings s, bool pass2, ref BreakResult res)
    {
        immutable long measure = h.ctx.measure;
        immutable long firstMeasure = h.ctx.measure - h.ctx.firstIndent;
        immutable long tolerance = s.tolerance;
        immutable long linePenalty = s.linePenalty;
        immutable long adj = s.adjDemerits;
        immutable long dbl = s.doubleHyphenDemerits;
        immutable long fin = s.finalHyphenDemerits;
        immutable lastItem = h.finalBreak;
        auto items = h.items;
        auto bps = h.breakpoints;
        auto cw = h.cw, cy = h.cy, cz = h.cz;
        auto ci = h.ci;

        nodes.length = 0;
        activeLen = 0;
        newNode(h, 0, -1, Fitness.decent, false, -1);
        addActive(0);

        size_t finalStart = 0;
        foreach (b; bps)
        {
            immutable isFinal = b == lastItem;
            const(Item)* it = &items[b];
            immutable bool isPen = it.kind == ItemKind.penalty;
            immutable long pen = isPen ? it.a : 0;
            immutable bool flagged = isPen && it.flag;
            immutable long preW = isPen && it.hasPre ? it.width : 0;
            immutable long cwb = cw[b], cyb = cy[b], czb = cz[b];
            immutable int cib = ci[b];
            long penDem = 0;
            if (pen >= 0 && pen < 10000)
                penDem = pen * pen;
            else if (pen > -10000 && pen < 0)
                penDem = -pen * pen;

            long[4] bestTotal = long.max;
            int[4] bestPrev = -1;
            size_t write = 0;
            immutable len = activeLen;
            auto act = active;
            auto nds = nodes;
            foreach (k; 0 .. len)
            {
                immutable id = act[k];
                const n = &nds[id];
                immutable long L = n.bp < 0 ? firstMeasure : measure;
                long w = cwb - n.sW;
                immutable long y = cyb - n.sY;
                immutable long z = czb - n.sZ;
                if (!pass2)
                {
                    if (w - z > L)
                        continue; // overfull for good: drop from the active set
                    act[write++] = id;
                }
                w += preW;
                immutable fit = evaluateLine(w, y, z, cib - n.sI > 0, L);
                if (!pass2 && (fit.kind != LineKind.normal || fit.badness > tolerance))
                    continue;
                long dem = (linePenalty + fit.badness) * (linePenalty + fit.badness) + penDem;
                if (flagged && n.flagged)
                    dem += dbl;
                immutable diff = fit.fitness > n.cls ? fit.fitness - n.cls : n.cls - fit.fitness;
                if (diff > 1)
                    dem += adj;
                if (isFinal && n.flagged)
                    dem += fin;
                immutable cand = n.total + dem;
                if (cand < bestTotal[fit.fitness])
                {
                    bestTotal[fit.fitness] = cand;
                    bestPrev[fit.fitness] = id;
                }
            }
            if (!pass2)
                activeLen = write;
            if (isFinal)
                finalStart = nodes.length;
            foreach (c; 0 .. 4)
            {
                if (bestPrev[c] < 0)
                    continue;
                newNode(h, bestTotal[c], b, c, flagged, bestPrev[c]);
                addActive(cast(int) nodes.length - 1);
            }
            if (!pass2 && !isFinal && activeLen == 0)
                return false;
        }
        if (nodes.length == finalStart || finalStart == 0)
            return false;
        // The final node: smallest total, ties to the smaller class then node number.
        size_t best = finalStart;
        foreach (i; finalStart + 1 .. nodes.length)
            if (nodes[i].total < nodes[best].total)
                best = i;
        res.demerits = nodes[best].total;
        int[] rev;
        for (int id = cast(int) best; nodes[id].bp >= 0; id = nodes[id].prev)
            rev ~= nodes[id].bp;
        res.breaks = new int[rev.length];
        foreach (i, v; rev)
            res.breaks[rev.length - 1 - i] = v;
        return true;
    }
}

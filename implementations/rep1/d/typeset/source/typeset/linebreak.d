/**
 * Total-fit (Knuth–Plass) line breaking over a horizontal list.
 *
 * Candidate lines are measured in O(1) with prefix sums. Pass 1 prunes
 * nodes whose line has become overfull; pass 2 (used only when pass 1 finds
 * no breaking) evaluates every node at every breakpoint.
 */
module typeset.linebreak;

import typeset.hlist : Item;
import typeset.units;

/// Parameters of the demerits formula.
struct BreakParams
{
    long tolerance;
    long linePenalty;
    long adjDemerits;
    long doubleHyphenDemerits;
    long finalHyphenDemerits;
}

/// Width, stretch and shrink of a candidate line.
struct LineSums
{
    long width; /// natural width, including pre-break text of the ending breakpoint
    long widthNoPre; /// natural width without that pre-break text
    long stretch, shrink;
    bool infinite;
}

/// Prefix sums over a list's items, for O(1) line measurement.
struct ListMetrics
{
    const(Item)[] items;
    private long[] pw, py, pz;
    private int[] pinf;
    private int[] firstKept; // smallest k >= i that is not a finite glue
    /// Breakpoint item indices (excluding the notional breakpoint 0).
    int[] breakpoints;

    this(const(Item)[] items)
    {
        this.items = items;
        immutable n = items.length;
        pw = new long[n + 1];
        py = new long[n + 1];
        pz = new long[n + 1];
        pinf = new int[n + 1];
        firstKept = new int[n + 2];
        foreach (i, ref it; items)
        {
            pw[i + 1] = pw[i];
            py[i + 1] = py[i];
            pz[i + 1] = pz[i];
            pinf[i + 1] = pinf[i];
            if (it.kind == Item.Kind.box)
                pw[i + 1] += it.width;
            else if (it.kind == Item.Kind.glue)
            {
                pw[i + 1] += it.width;
                py[i + 1] += it.stretch;
                pz[i + 1] += it.shrink;
                if (it.infinite)
                    ++pinf[i + 1];
            }
        }
        firstKept[n] = cast(int) n;
        firstKept[n + 1] = cast(int) n;
        foreach_reverse (i; 0 .. n)
            firstKept[i] = (items[i].kind == Item.Kind.glue && !items[i].infinite) ? firstKept[i + 1] : cast(int) i;
        foreach (i, ref it; items)
        {
            if (i == 0)
                continue;
            if (it.kind == Item.Kind.glue && items[i - 1].kind == Item.Kind.box)
                breakpoints ~= cast(int) i;
            else if (it.kind == Item.Kind.penalty && it.penalty < 10_000)
                breakpoints ~= cast(int) i;
        }
        // item 0 can never be a breakpoint: it has no predecessor (a glue) and
        // lists never start with a breaking penalty.
    }

    /// Index of the first item of the line that starts after breakpoint `a`
    /// (leading finite glue removed), clamped to `b`.
    int lineStart(int a, int b) const
    {
        immutable s = firstKept[a == 0 ? 0 : a + 1];
        return s < b ? s : b;
    }

    /// Sums of the line from breakpoint `a` to breakpoint `b`.
    LineSums line(int a, int b) const
    {
        immutable s = lineStart(a, b);
        LineSums r;
        r.widthNoPre = pw[b] - pw[s];
        r.stretch = py[b] - py[s];
        r.shrink = pz[b] - pz[s];
        r.infinite = pinf[b] - pinf[s] > 0;
        r.width = r.widthNoPre;
        if (items[b].kind == Item.Kind.penalty)
            r.width += items[b].preWidth;
        return r;
    }

    /// Total natural width of the whole list (the final infinite glue is 0 wide).
    long naturalWidth() const
    {
        return pw[items.length];
    }
}

/// The outcome of breaking one list.
struct Breaking
{
    int[] breaks; /// chosen breakpoint item indices, ending with the final one
    long totalDemerits;
    bool emergency; /// pass 2 was needed
}

private enum Status : ubyte
{
    ok,
    unstretchable,
    overfull
}

/// Badness and fitness class of a line (0 tight, 1 decent, 2 loose, 3 very loose).
Status classify(in LineSums s, long measure, out long badness, out int fitness) pure nothrow @safe @nogc
{
    immutable d = measure - s.width;
    if (d >= 0 && s.infinite)
    {
        badness = 0;
        fitness = 1;
        return Status.ok;
    }
    if (d == 0)
    {
        badness = 0;
        fitness = 1;
        return Status.ok;
    }
    if (d > 0)
    {
        if (s.stretch == 0)
        {
            badness = 10_000;
            fitness = 3;
            return Status.unstretchable;
        }
        badness = cubeRatio100(d, s.stretch, 10_000);
        fitness = d > s.stretch ? 3 : (2 * d > s.stretch ? 2 : 1);
        return Status.ok;
    }
    immutable e = -d;
    if (s.shrink == 0 || e > s.shrink)
    {
        badness = 10_000;
        fitness = 0;
        return Status.overfull;
    }
    badness = cubeRatio100(e, s.shrink, 10_000);
    fitness = 2 * e > s.shrink ? 0 : 1;
    return Status.ok;
}

/// Breaks the list `m.items` into lines of width `measure`
/// (`measure - firstIndent` for the first line).
Breaking breakLines(ref const ListMetrics m, long measure, long firstIndent, in BreakParams p)
{
    auto r = runPass(m, measure, firstIndent, p, false);
    if (r.breaks.length == 0)
    {
        r = runPass(m, measure, firstIndent, p, true);
        r.emergency = true;
    }
    return r;
}

private Breaking runPass(ref const ListMetrics m, long measure, long firstIndent, in BreakParams p, bool pass2)
{
    const items = m.items;
    immutable finalBp = cast(int)(items.length - 1);

    // node table (structure of arrays)
    int[] nbp = [0];
    ubyte[] ncls = [1];
    long[] ntotal = [0L];
    int[] nprev = [-1];
    int[] nactive = [0]; // active node numbers (pass 1)
    size_t firstNode = 0;

    foreach (b; m.breakpoints)
    {
        long[4] bestTotal;
        int[4] bestPred = [-1, -1, -1, -1];
        long penalty = 0;
        bool flag = false;
        if (items[b].kind == Item.Kind.penalty)
        {
            penalty = items[b].penalty;
            flag = items[b].flagged;
        }
        immutable isFinal = b == finalBp;

        // iterate nodes
        size_t keep = 0;
        immutable count = pass2 ? nbp.length : nactive.length;
        foreach (idx; 0 .. count)
        {
            immutable n = pass2 ? cast(int) idx : nactive[idx];
            immutable a = nbp[n];
            immutable L = a == 0 ? measure - firstIndent : measure;
            immutable sums = m.line(a, b);
            long bad;
            int fit;
            immutable st = classify(sums, L, bad, fit);
            if (!pass2)
            {
                if (sums.widthNoPre - sums.shrink > L)
                    continue; // overfull for good: leaves the active set
                nactive[keep++] = n;
                if (st != Status.ok || bad > p.tolerance)
                    continue;
            }
            // demerits of this line
            long dem = (p.linePenalty + bad) * (p.linePenalty + bad);
            if (penalty >= 0 && penalty < 10_000)
                dem += penalty * penalty;
            else if (penalty > -10_000 && penalty < 0)
                dem -= penalty * penalty;
            immutable flag0 = a != 0 && items[a].kind == Item.Kind.penalty && items[a].flagged;
            if (flag && flag0)
                dem += p.doubleHyphenDemerits;
            immutable c0 = ncls[n];
            if ((fit > c0 ? fit - c0 : c0 - fit) > 1)
                dem += p.adjDemerits;
            if (isFinal && flag0)
                dem += p.finalHyphenDemerits;
            immutable total = ntotal[n] + dem;
            if (bestPred[fit] < 0 || total < bestTotal[fit])
            {
                bestTotal[fit] = total;
                bestPred[fit] = n;
            }
        }
        if (!pass2)
            nactive = nactive[0 .. keep];
        foreach (c; 0 .. 4)
        {
            if (bestPred[c] < 0)
                continue;
            immutable id = cast(int) nbp.length;
            nbp ~= b;
            ncls ~= cast(ubyte) c;
            ntotal ~= bestTotal[c];
            nprev ~= bestPred[c];
            if (!pass2)
                nactive ~= id;
        }
        if (!pass2 && nactive.length == 0)
            return Breaking.init;
    }

    // best node at the final breakpoint (the last created nodes)
    int best = -1;
    foreach (n; 1 .. cast(int) nbp.length)
    {
        if (nbp[n] != finalBp)
            continue;
        if (best < 0 || ntotal[n] < ntotal[best])
            best = n;
    }
    if (best < 0)
        return Breaking.init;
    Breaking r;
    r.totalDemerits = ntotal[best];
    int[] rev;
    for (int n = best; n > 0; n = nprev[n])
        rev ~= nbp[n];
    foreach_reverse (v; rev)
        r.breaks ~= v;
    return r;
}

unittest
{
    // Example 5: "The quick brown fox." on one justified line.
    Item box(long w)
    {
        Item i;
        i.kind = Item.Kind.box;
        i.width = w;
        return i;
    }

    Item glue()
    {
        Item i;
        i.kind = Item.Kind.glue;
        i.width = 2540;
        i.stretch = 1270;
        i.shrink = 850;
        return i;
    }

    Item pen(long p)
    {
        Item i;
        i.kind = Item.Kind.penalty;
        i.penalty = p;
        return i;
    }

    Item[] items = [box(15_630), glue(), box(22_240), glue(), box(25_140), glue(), box(15_810), pen(10_000)];
    Item inf;
    inf.kind = Item.Kind.glue;
    inf.infinite = true;
    items ~= inf;
    items ~= pen(-10_000);
    auto m = ListMetrics(items);
    auto r = breakLines(m, 142_000, 0, BreakParams(1000, 10, 10_000, 10_000, 5000));
    assert(r.breaks == [9] && r.totalDemerits == 100 && !r.emergency);
}

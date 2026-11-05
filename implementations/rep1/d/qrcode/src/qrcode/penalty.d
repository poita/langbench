/// Mask penalty scoring (rules N1-N4 of ISO/IEC 18004).
module qrcode.penalty;

private enum uint patternA = 0x5D0; // #.###.#....
private enum uint patternB = 0x05D; // ....#.###.#

/**
 * Penalty contribution of the rows (`stride == 1`, `step == size`) or the
 * columns (`stride == size`, `step == 1`) of the grid: N1 runs plus N3
 * finder-like patterns, in a single scan per line.
 */
private int scanLines(const(ubyte)[] m, int n, int lineStep, int elemStep) @safe pure nothrow @nogc
{
    int total = 0;
    foreach (line; 0 .. n)
    {
        size_t p = cast(size_t) line * lineStep;
        ubyte color = m[p];
        int run = 1;
        uint window = color;
        int count = 1;
        foreach (k; 1 .. n)
        {
            p += elemStep;
            const c = m[p];
            if (c == color)
                ++run;
            else
            {
                if (run >= 5)
                    total += run - 2;
                color = c;
                run = 1;
            }
            window = ((window << 1) | c) & 0x7FF;
            ++count;
            if (count >= 11 && (window == patternA || window == patternB))
            {
                // each pattern is counted independently
                total += 40;
            }
        }
        if (run >= 5)
            total += run - 2;
    }
    return total;
}

/// Total penalty score of a complete symbol of side `n` (lower is better).
int penaltyScore(const(ubyte)[] m, int n) @safe pure nothrow @nogc
in (m.length == cast(size_t) n * n)
{
    int total = scanLines(m, n, n, 1) + scanLines(m, n, 1, n);

    // N2: 2x2 blocks of one colour, plus the dark count for N4.
    size_t dark = 0;
    foreach (y; 0 .. n)
    {
        const r0 = m[y * n .. (y + 1) * n];
        foreach (x; 0 .. n)
            dark += r0[x];
        if (y + 1 < n)
        {
            const r1 = m[(y + 1) * n .. (y + 2) * n];
            foreach (x; 0 .. n - 1)
            {
                const c = r0[x];
                if (c == r0[x + 1] && c == r1[x] && c == r1[x + 1])
                    total += 3;
            }
        }
    }

    // N4: whole 5% steps of deviation from 50% dark.
    const t = cast(long) n * n;
    long diff = 20 * cast(long) dark - 10 * t;
    if (diff < 0)
        diff = -diff;
    total += 10 * cast(int)(diff / t);
    return total;
}

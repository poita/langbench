/// Mask penalty scoring (rules N1..N4).
module qrcode.penalty;

/// Total penalty of a complete symbol: `cells` is `n * n` row-major (1 = dark).
int penaltyScore(const(ubyte)[] cells, int n) @safe pure nothrow @nogc
{
    int total = 0;

    // N1 and N3 run along every row (stride 1) and every column (stride n).
    foreach (line; 0 .. n)
    {
        total += linePenalty(cells, line * n, 1, n);
        total += linePenalty(cells, line, n, n);
    }

    // N2: 2x2 blocks of one colour.
    foreach (y; 0 .. n - 1)
        foreach (x; 0 .. n - 1)
        {
            const c = cells[y * n + x];
            if (c == cells[y * n + x + 1] && c == cells[(y + 1) * n + x] && c == cells[(y + 1) * n + x + 1])
                total += 3;
        }

    // N4: balance of dark and light.
    int dark = 0;
    foreach (c; cells)
        dark += c;
    const t = n * n;
    const diff = 20 * dark - 10 * t;
    total += 10 * ((diff < 0 ? -diff : diff) / t);
    return total;
}

/// N1 + N3 contribution of one line of `n` modules starting at `start` with step `stride`.
private int linePenalty(const(ubyte)[] cells, int start, int stride, int n) @safe pure nothrow @nogc
{
    int total = 0;

    // N1: runs of 5 or more.
    int run = 1;
    foreach (i; 1 .. n)
    {
        if (cells[start + i * stride] == cells[start + (i - 1) * stride])
            run++;
        else
        {
            if (run >= 5) total += 3 + run - 5;
            run = 1;
        }
    }
    if (run >= 5) total += 3 + run - 5;

    // N3: finder-like patterns, tracked with 11-bit windows (bit set = dark).
    enum uint patA = 0b10111010000; // #.###.#....
    enum uint patB = 0b00001011101; // ....#.###.#
    uint window = 0;
    foreach (i; 0 .. n)
    {
        window = ((window << 1) | cells[start + i * stride]) & 0x7FF;
        if (i >= 10)
        {
            if (window == patA) total += 40;
            if (window == patB) total += 40;
        }
    }
    return total;
}

@safe pure nothrow unittest
{
    // A uniformly light 5x5 symbol: N1 = 10 rows/cols * 3 = 30; N2 = 16 blocks * 3 = 48; N4: k = 10.
    ubyte[25] cells;
    assert(penaltyScore(cells[], 5) == 30 + 48 + 100);
}

@safe pure nothrow unittest
{
    // N3 on a single row inside a larger symbol: only the line penalty is tested here.
    enum n = 15;
    ubyte[n * n] cells;
    // Row 0 = "....#.###.#...." -> both patterns found (80), no run >= 5 of either colour except none.
    immutable string row = "....#.###.#....";
    foreach (i, ch; row)
        cells[i] = ch == '#' ? 1 : 0;
    assert(linePenalty(cells[], 0, 1, n) == 80);
}

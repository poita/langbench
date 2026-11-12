/// The module grid: function patterns, data placement, masking and format information.
module qrcode.matrix;

import qrcode.tables;

/// A square grid of modules (1 = dark, 0 = light) plus a map of function modules.
struct Grid
{
    /// Side length in modules.
    int size;
    /// Row-major module values, `size * size` entries of 0 or 1.
    ubyte[] cells;
    /// Row-major flags; non-zero marks a function module (never masked, never data).
    ubyte[] isFunction;

    /// Creates an all-light grid of the given size.
    this(int size) @safe pure nothrow
    {
        this.size = size;
        cells = new ubyte[size * size];
        isFunction = new ubyte[size * size];
    }

    /// Module value at column `x`, row `y`.
    ubyte opIndex(int x, int y) const @safe pure nothrow @nogc { return cells[y * size + x]; }

    private void setFunction(int x, int y, bool dark) @safe pure nothrow @nogc
    {
        cells[y * size + x] = dark ? 1 : 0;
        isFunction[y * size + x] = 1;
    }
}

/// Builds a grid of version `ver` containing every function module: finder, timing and alignment
/// patterns, the dark module, version information, and a reserved (light) format area.
Grid drawFunctionPatterns(int ver) @safe pure nothrow
{
    const n = symbolSize(ver);
    auto g = Grid(n);

    // Timing patterns.
    foreach (i; 0 .. n)
    {
        g.setFunction(i, 6, i % 2 == 0);
        g.setFunction(6, i, i % 2 == 0);
    }

    // Finder patterns with separators.
    void finder(int cx, int cy)
    {
        foreach (dy; -4 .. 5)
            foreach (dx; -4 .. 5)
            {
                const x = cx + dx, y = cy + dy;
                if (x < 0 || y < 0 || x >= n || y >= n)
                    continue;
                const d = (dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy);
                g.setFunction(x, y, d == 0 || d == 1 || d == 3);
            }
    }
    finder(3, 3);
    finder(n - 4, 3);
    finder(3, n - 4);

    // Alignment patterns.
    const pos = alignmentPositions(ver);
    foreach (i, py; pos)
        foreach (j, px; pos)
        {
            const last = pos.length - 1;
            if ((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0))
                continue;
            foreach (dy; -2 .. 3)
                foreach (dx; -2 .. 3)
                {
                    const d = (dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy);
                    g.setFunction(px + dx, py + dy, d != 1);
                }
        }

    // Reserve the format areas (written for real by drawFormat), then the dark module.
    foreach (i; 0 .. 15)
        drawFormatBit(g.cells, g.isFunction, n, i, false, true);
    g.setFunction(8, n - 8, true);

    if (ver >= 7)
    {
        uint rem = ver;
        foreach (_; 0 .. 12)
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        const bits = (cast(uint) ver << 12) | rem;
        foreach (i; 0 .. 18)
        {
            const dark = ((bits >> i) & 1) != 0;
            const a = n - 11 + i % 3, b = i / 3;
            g.setFunction(a, b, dark);
            g.setFunction(b, a, dark);
        }
    }
    return g;
}

/// The 15 format bits (BCH-protected, XOR-masked) for an error correction level and mask.
uint formatBitsFor(Ecl ecl, int mask) @safe pure nothrow @nogc
in (mask >= 0 && mask < 8)
{
    const data = (cast(uint) formatBits(ecl) << 3) | mask;
    uint rem = data;
    foreach (_; 0 .. 10)
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return ((data << 10) | rem) ^ 0x5412;
}

private void drawFormatBit(ubyte[] cells, ubyte[] isFunction, int n, int i, bool dark, bool markFunction)
    @safe pure nothrow @nogc
{
    void put(int x, int y)
    {
        cells[y * n + x] = dark ? 1 : 0;
        if (markFunction)
            isFunction[y * n + x] = 1;
    }
    // First copy around the top-left finder.
    if (i < 6) put(8, i);
    else if (i == 6) put(8, 7);
    else if (i == 7) put(8, 8);
    else if (i == 8) put(7, 8);
    else put(14 - i, 8);
    // Second copy.
    if (i < 8) put(n - 1 - i, 8);
    else put(8, n - 15 + i);
}

/// Writes both copies of the format information into `cells` (a grid of side `n`).
void drawFormat(ubyte[] cells, int n, Ecl ecl, int mask) @safe pure nothrow @nogc
{
    const bits = formatBitsFor(ecl, mask);
    ubyte[] none;
    foreach (i; 0 .. 15)
        drawFormatBit(cells, none, n, i, ((bits >> i) & 1) != 0, false);
}

/// Places the codeword bits (MSB first) along the zigzag in all non-function modules.
/// Modules left over stay light.
void placeData(ref Grid g, const(ubyte)[] codewords) @safe pure nothrow @nogc
{
    const n = g.size;
    const totalBits = codewords.length * 8;
    size_t k = 0;
    for (int right = n - 1; right >= 1; right -= 2)
    {
        if (right == 6)
            right = 5;
        const upward = ((right + 1) & 2) == 0;
        foreach (vert; 0 .. n)
        {
            const y = upward ? n - 1 - vert : vert;
            foreach (j; 0 .. 2)
            {
                const x = right - j;
                if (g.isFunction[y * n + x] || k >= totalBits)
                    continue;
                g.cells[y * n + x] = (codewords[k >> 3] >> (7 - (k & 7))) & 1;
                k++;
            }
        }
    }
}

/// Whether mask pattern `mask` inverts the module at column `x`, row `y`.
bool maskApplies(int mask, int x, int y) @safe pure nothrow @nogc
{
    switch (mask)
    {
    case 0: return (x + y) % 2 == 0;
    case 1: return y % 2 == 0;
    case 2: return x % 3 == 0;
    case 3: return (x + y) % 3 == 0;
    case 4: return (x / 3 + y / 2) % 2 == 0;
    case 5: return (x * y) % 2 + (x * y) % 3 == 0;
    case 6: return ((x * y) % 2 + (x * y) % 3) % 2 == 0;
    case 7: return ((x + y) % 2 + (x * y) % 3) % 2 == 0;
    default: assert(0, "mask must be in 0..7");
    }
}

/// Inverts the data modules selected by `mask`. `cells` and `isFunction` are `n * n` row-major arrays.
void applyMask(ubyte[] cells, const(ubyte)[] isFunction, int n, int mask) @safe pure nothrow @nogc
{
    foreach (y; 0 .. n)
        foreach (x; 0 .. n)
            if (!isFunction[y * n + x] && maskApplies(mask, x, y))
                cells[y * n + x] ^= 1;
}

@safe pure nothrow unittest
{
    // Function-module counts: a version 1 symbol has 21*21 - 208 = 233 function modules.
    auto g = drawFunctionPatterns(1);
    size_t fn;
    foreach (f; g.isFunction) fn += f;
    assert(fn == 21 * 21 - 208);
    assert(g[8, 13] == 1); // dark module
    assert(g[0, 0] == 1 && g[1, 1] == 0 && g[2, 2] == 1 && g[7, 0] == 0);
}

@safe pure nothrow unittest
{
    // For every version, function modules leave exactly rawDataModules room.
    foreach (v; minVersion .. maxVersion + 1)
    {
        auto g = drawFunctionPatterns(v);
        size_t free;
        foreach (f; g.isFunction) free += !f;
        assert(free == rawDataModules(v), "wrong data module count");
    }
}

@safe pure nothrow @nogc unittest
{
    // Format information for M / mask 0 is 101010000010010 (all-zero data xor 0x5412).
    assert(formatBitsFor(Ecl.medium, 0) == 0x5412);
    // Known value from the standard: L / mask 4 -> 110011000101111.
    assert(formatBitsFor(Ecl.low, 4) == 0b110011000101111);
}

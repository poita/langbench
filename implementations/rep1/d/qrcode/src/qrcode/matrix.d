/**
 * The module matrix: function patterns, codeword placement, masking and
 * format/version information.
 *
 * A symbol is a flat, row-major array of `size*size` bytes (0 light, 1 dark)
 * indexed `y*size + x`, with a parallel array flagging function modules.
 */
module qrcode.matrix;

import qrcode.tables;

/// A working grid together with its function-module map.
struct Grid
{
    int size;
    ubyte[] modules; /// 0 = light, 1 = dark
    ubyte[] isFunction; /// 1 where the module is a function module

    /// Allocate an all-light grid for a version.
    static Grid create(int ver) @safe pure nothrow
    {
        Grid g;
        g.size = symbolSize(ver);
        g.modules = new ubyte[g.size * g.size];
        g.isFunction = new ubyte[g.size * g.size];
        return g;
    }

    /// Set a module and mark it as a function module.
    void setFunction(int x, int y, bool dark) @safe pure nothrow @nogc
    {
        modules[y * size + x] = dark;
        isFunction[y * size + x] = 1;
    }
}

private void drawFinder(ref Grid g, int cx, int cy) @safe pure nothrow @nogc
{
    foreach (dy; -4 .. 5)
        foreach (dx; -4 .. 5)
        {
            const x = cx + dx, y = cy + dy;
            if (x < 0 || y < 0 || x >= g.size || y >= g.size)
                continue;
            const d = (dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy);
            g.setFunction(x, y, d == 0 || d == 1 || d == 3);
        }
}

private void drawAlignment(ref Grid g, int cx, int cy) @safe pure nothrow @nogc
{
    foreach (dy; -2 .. 3)
        foreach (dx; -2 .. 3)
        {
            const d = (dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy);
            g.setFunction(cx + dx, cy + dy, d != 1);
        }
}

/// The 18-bit version information word (BCH(18,6)) for `ver >= 7`.
uint versionBits(int ver) @safe pure nothrow @nogc
{
    uint rem = ver;
    foreach (_; 0 .. 12)
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return (cast(uint) ver << 12) | rem;
}

/// The 15-bit format information word (BCH(15,5), masked) for `ecl` and `mask`.
uint formatWord(Ecl ecl, int mask) @safe pure nothrow @nogc
{
    const data = cast(uint)((formatBits(ecl) << 3) | mask);
    uint rem = data;
    foreach (_; 0 .. 10)
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return ((data << 10) | rem) ^ 0x5412;
}

/// Write the format information for (`ecl`, `mask`) into both reserved areas.
void drawFormat(ref Grid g, Ecl ecl, int mask) @safe pure nothrow @nogc
{
    const bits = formatWord(ecl, mask);
    const n = g.size;
    bool bit(int i) { return ((bits >> i) & 1) != 0; }

    foreach (i; 0 .. 6)
        g.setFunction(8, i, bit(i));
    g.setFunction(8, 7, bit(6));
    g.setFunction(8, 8, bit(7));
    g.setFunction(7, 8, bit(8));
    foreach (i; 9 .. 15)
        g.setFunction(14 - i, 8, bit(i));

    foreach (i; 0 .. 8)
        g.setFunction(n - 1 - i, 8, bit(i));
    foreach (i; 8 .. 15)
        g.setFunction(8, n - 15 + i, bit(i));
    g.setFunction(8, n - 8, true); // the always-dark module
}

/**
 * Build the base grid for a version: all function patterns drawn and
 * marked (format areas reserved, light), data modules still light.
 */
Grid buildFunctionPatterns(int ver, Ecl ecl) @safe pure nothrow
{
    auto g = Grid.create(ver);
    const n = g.size;

    foreach (i; 8 .. n - 8)
    {
        g.setFunction(i, 6, i % 2 == 0);
        g.setFunction(6, i, i % 2 == 0);
    }
    drawFinder(g, 3, 3);
    drawFinder(g, n - 4, 3);
    drawFinder(g, 3, n - 4);

    const pos = alignmentPositions(ver);
    foreach (i, py; pos)
        foreach (j, px; pos)
        {
            const last = pos.length - 1;
            if ((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0))
                continue;
            drawAlignment(g, px, py);
        }

    drawFormat(g, ecl, 0); // reserve the area; rewritten per mask

    if (ver >= 7)
    {
        const bits = versionBits(ver);
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

/// Place codeword bits along the zigzag; remaining modules stay light.
void placeCodewords(ref Grid g, const(ubyte)[] codewords) @safe pure nothrow @nogc
{
    const n = g.size;
    const totalBits = codewords.length * 8;
    size_t i = 0;
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
                const idx = y * n + x;
                if (g.isFunction[idx] || i >= totalBits)
                    continue;
                g.modules[idx] = (codewords[i >> 3] >> (7 - (i & 7))) & 1;
                ++i;
            }
        }
    }
}

/// Whether mask pattern `mask` inverts module (`x`, `y`).
bool maskCondition(int mask, int x, int y) @safe pure nothrow @nogc
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
    default: assert(0, "mask out of range");
    }
}

/**
 * Render `base` with mask pattern `mask` into `scratch` (which must have
 * the same size) and write the format information for (`ecl`, `mask`).
 * `base` is left untouched.
 */
void renderMask(ref const Grid base, ubyte[] scratch, Ecl ecl, int mask) @safe pure nothrow @nogc
in (scratch.length == base.modules.length)
{
    const n = base.size;
    scratch[] = base.modules[];
    size_t idx = 0;
    foreach (y; 0 .. n)
        foreach (x; 0 .. n)
        {
            if (!base.isFunction[idx] && maskCondition(mask, x, y))
                scratch[idx] ^= 1;
            ++idx;
        }

    const bits = formatWord(ecl, mask);
    bool bit(int i) { return ((bits >> i) & 1) != 0; }
    void set(int x, int y, bool dark) { scratch[y * n + x] = dark; }
    foreach (i; 0 .. 6)
        set(8, i, bit(i));
    set(8, 7, bit(6));
    set(8, 8, bit(7));
    set(7, 8, bit(8));
    foreach (i; 9 .. 15)
        set(14 - i, 8, bit(i));
    foreach (i; 0 .. 8)
        set(n - 1 - i, 8, bit(i));
    foreach (i; 8 .. 15)
        set(8, n - 15 + i, bit(i));
}

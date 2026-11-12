/// The 64x32 monochrome display.
module chip8.display;

/// A 64x32 1-bit frame buffer with XOR drawing and wrap-around.
struct Display
{
    /// Width in pixels.
    enum width = 64;
    /// Height in pixels.
    enum height = 32;

    private bool[width * height] pixels;

    /// Turns every pixel off.
    void clear() @safe pure nothrow @nogc
    {
        pixels[] = false;
    }

    /// Whether the pixel at column `x`, row `y` is lit.
    bool opIndex(size_t x, size_t y) const @safe pure nothrow @nogc
    in (x < width && y < height)
    {
        return pixels[y * width + x];
    }

    /**
     * XORs one pixel; coordinates wrap modulo the display size.
     * Returns: `true` if the pixel was lit before (i.e. it was turned off).
     */
    bool toggle(size_t x, size_t y) @safe pure nothrow @nogc
    {
        auto p = &pixels[(y & (height - 1)) * width + (x & (width - 1))];
        const wasOn = *p;
        *p = !wasOn;
        return wasOn;
    }

    /**
     * XORs a sprite whose rows are `rows` (one byte each, most significant bit
     * leftmost) with its origin at `(x, y)`; the origin is reduced modulo the
     * display size and pixels beyond an edge wrap around.
     * Returns: `true` if any lit pixel was turned off.
     */
    bool drawSprite(size_t x, size_t y, scope const(ubyte)[] rows) @safe pure nothrow @nogc
    {
        bool collision = false;
        const sx = x & (width - 1), sy = y & (height - 1);
        foreach (row, b; rows)
            foreach (bit; 0 .. 8)
                if ((b >> (7 - bit)) & 1)
                    collision |= toggle(sx + bit, sy + row);
        return collision;
    }

    /// Number of lit pixels.
    size_t litCount() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (p; pixels)
            n += p;
        return n;
    }
}

@safe pure nothrow @nogc unittest
{
    Display d;
    assert(d.litCount == 0);
    assert(!d.toggle(3, 4));
    assert(d[3, 4]);
    assert(d.toggle(3 + 64, 4 + 32)); // wraps; turns it off again
    assert(!d[3, 4]);
}

@safe pure nothrow unittest
{
    Display d;
    static immutable ubyte[2] rows = [0xF0, 0x90];
    assert(!d.drawSprite(62, 31, rows[]));
    assert(d[62, 31] && d[63, 31] && d[0, 31] && d[1, 31]);
    assert(d[62, 0] && !d[63, 0] && !d[0, 0] && d[1, 0]);
    assert(d.litCount == 6);
    assert(d.drawSprite(62, 31, rows[]));
    assert(d.litCount == 0);
    d.drawSprite(0, 0, rows[]);
    d.clear();
    assert(d.litCount == 0);
}

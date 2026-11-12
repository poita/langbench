/// The 64x32 monochrome framebuffer.
module chip8.display;

/// Display width in pixels.
enum size_t width = 64;
/// Display height in pixels.
enum size_t height = 32;

/// A 64x32 one-bit-per-pixel display; sprites XOR and wrap around both edges.
struct Display
{
    /// Pixel state, row-major; each element is 0 or 1.
    ubyte[width * height] pixels;

    /// Turn all pixels off.
    void clear() @safe pure nothrow @nogc
    {
        pixels[] = 0;
    }

    /// Is the pixel at (`x`, `y`) lit?  Coordinates are wrapped.
    bool opIndex(size_t x, size_t y) const @safe pure nothrow @nogc
    {
        return pixels[(y & (height - 1)) * width + (x & (width - 1))] != 0;
    }

    /**
     * XOR one sprite row (8 pixels, MSB leftmost) at column `sx`, row `py`,
     * wrapping horizontally and vertically.
     * Returns: true if any lit pixel was turned off.
     */
    bool xorRow(uint sx, uint py, ubyte bits) @safe pure nothrow @nogc
    {
        bool collided = false;
        immutable rowBase = (py & (height - 1)) * width;
        foreach (bit; 0 .. 8)
        {
            if ((bits >> (7 - bit)) & 1)
            {
                auto p = &pixels[rowBase + ((sx + bit) & (width - 1))];
                collided |= *p != 0;
                *p ^= 1;
            }
        }
        return collided;
    }

    /// Render as 32 lines of 64 `#`/`.` characters, each ending in `\n`.
    string render() const @safe pure nothrow
    {
        auto buf = new char[(width + 1) * height];
        size_t o;
        foreach (y; 0 .. height)
        {
            foreach (x; 0 .. width)
                buf[o++] = pixels[y * width + x] ? '#' : '.';
            buf[o++] = '\n';
        }
        return (() @trusted => cast(string) buf)();
    }
}

@safe pure nothrow unittest
{
    Display d;
    assert(!d.xorRow(62, 31, 0xF0));
    assert(d[62, 31] && d[63, 31] && d[0, 31] && d[1, 31] && !d[2, 31]);
    assert(d.xorRow(62, 31, 0xF0));
    foreach (p; d.pixels)
        assert(p == 0);
    d.xorRow(0, 0, 0x80);
    d.clear();
    assert(!d[0, 0]);
    assert(d.render().length == 65 * 32);
}

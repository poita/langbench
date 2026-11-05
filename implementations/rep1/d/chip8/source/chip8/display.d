/// The 64×32 monochrome display, stored as one 64-bit word per row.
module chip8.display;

import core.bitop : ror;
import chip8.constants;

/++
    Display state. Row `y` is one `ulong`; column 0 is the most significant bit
    and column 63 the least significant bit.
+/
struct Display
{
    /// One word per row.
    ulong[displayHeight] rows;

    /// Turn every pixel off.
    void clear() pure nothrow @safe @nogc
    {
        rows[] = 0;
    }

    /// Whether the pixel at column `x`, row `y` is lit (coordinates are wrapped).
    bool opIndex(size_t x, size_t y) const pure nothrow @safe @nogc
    {
        return ((rows[y & (displayHeight - 1)] >> (63 - (x & (displayWidth - 1)))) & 1) != 0;
    }

    /++
        XOR one 8-pixel sprite row at origin `(sx, sy)`, wrapping at the edges.

        Params:
            sx   = column of the sprite's leftmost bit (0..63)
            row  = destination row, wrapped to 0..31
            bits = the sprite byte, most significant bit leftmost

        Returns: `true` if any lit pixel was turned off (collision).
    +/
    pragma(inline, true)
    bool xorByte(uint sx, uint row, ubyte bits) pure nothrow @safe @nogc
    {
        immutable ulong mask = ror(cast(ulong) bits << 56, sx & 63);
        ulong* r = &rows[row & (displayHeight - 1)];
        immutable hit = (*r & mask) != 0;
        *r ^= mask;
        return hit;
    }

    /// Render as 32 lines of 64 characters (`#` lit, `.` unlit), each ending in `\n`.
    char[] render() const pure nothrow @safe
    {
        auto buf = new char[displayHeight * (displayWidth + 1)];
        renderInto(buf);
        return buf;
    }

    /// ditto; writes into `buf`, which must hold at least 32 * 65 chars.
    void renderInto(char[] buf) const pure nothrow @safe @nogc
    in (buf.length >= displayHeight * (displayWidth + 1))
    {
        size_t o = 0;
        foreach (w; rows)
        {
            foreach (x; 0 .. displayWidth)
                buf[o++] = ((w >> (63 - x)) & 1) ? '#' : '.';
            buf[o++] = '\n';
        }
    }
}

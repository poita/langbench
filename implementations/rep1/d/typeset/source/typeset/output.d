/// Output formatting: growable text buffer, per-page item collection and
/// ordering, and the `layout.txt` / `report.txt` / `error.txt` writers.
module typeset.output;

import std.algorithm : sort;
import typeset.fonts : faceNames;

/// A simple append-only text buffer.
struct Buf
{
    char[] data; ///
    size_t len; ///

    /// Appends text.
    void put(const(char)[] s) pure nothrow @safe
    {
        reserve(s.length);
        data[len .. len + s.length] = s[];
        len += s.length;
    }

    /// Appends one character.
    void put(char c) pure nothrow @safe
    {
        reserve(1);
        data[len++] = c;
    }

    /// Appends a decimal integer.
    void putInt(long v) pure nothrow @safe
    {
        char[24] tmp;
        size_t p = tmp.length;
        bool neg = v < 0;
        ulong u = neg ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
        do
        {
            tmp[--p] = cast(char)('0' + u % 10);
            u /= 10;
        }
        while (u != 0);
        if (neg)
            tmp[--p] = '-';
        put(tmp[p .. $]);
    }

    /// The accumulated text.
    const(char)[] opSlice() const pure nothrow @nogc @safe
    {
        return data[0 .. len];
    }

    private void reserve(size_t extra) pure nothrow @safe
    {
        if (len + extra > data.length)
        {
            size_t n = data.length ? data.length * 2 : 256;
            while (n < len + extra)
                n *= 2;
            data.length = n;
        }
    }
}

/// Output regions in sort-rank order.
enum Region : ubyte
{
    header,
    float_,
    body_,
    footnote,
    footer,
}

private immutable string[5] regionNames = ["header", "float", "body", "footnote", "footer"];

private enum ItemRank : ubyte
{
    text,
    rule,
    box,
}

private struct OutItem
{
    long y, x;
    uint off, len;
    Region region;
    ItemRank kind;
}

/// The items of one page, formatted as they are added and sorted on render.
final class OutPage
{
    string label; /// page label
    private
    {
        OutItem[] items;
        Buf buf;
    }

    private size_t begin()
    {
        return buf.len;
    }

    private void end(size_t start, Region r, ItemRank k, long x, long y)
    {
        items ~= OutItem(y, x, cast(uint) start, cast(uint)(buf.len - start), r, k);
    }

    /// Adds a `text` item.
    void text(Region r, ubyte face, long size, long x, long y, long width, const(char)[] s)
    {
        immutable st = begin();
        buf.put("  text ");
        buf.put(regionNames[r]);
        buf.put(' ');
        buf.put(faceNames[face]);
        buf.put(' ');
        buf.putInt(size);
        buf.put(' ');
        buf.putInt(x);
        buf.put(' ');
        buf.putInt(y);
        buf.put(' ');
        buf.putInt(width);
        buf.put(" \"");
        foreach (c; s)
        {
            if (c == '\\' || c == '"')
                buf.put('\\');
            buf.put(c);
        }
        buf.put('"');
        end(st, r, ItemRank.text, x, y);
    }

    /// Adds a `rule` item (`y` is the top edge).
    void rule(Region r, long x, long y, long width, long thickness)
    {
        immutable st = begin();
        buf.put("  rule ");
        buf.put(regionNames[r]);
        foreach (v; [x, y, width, thickness])
        {
            buf.put(' ');
            buf.putInt(v);
        }
        end(st, r, ItemRank.rule, x, y);
    }

    /// Adds a `box` item (`y` is the top edge).
    void box(Region r, long x, long y, long width, long height)
    {
        immutable st = begin();
        buf.put("  box ");
        buf.put(regionNames[r]);
        foreach (v; [x, y, width, height])
        {
            buf.put(' ');
            buf.putInt(v);
        }
        end(st, r, ItemRank.box, x, y);
    }

    /// Number of items added so far.
    size_t length() const
    {
        return items.length;
    }

    /// Appends the sorted item lines to `outBuf`.
    void render(ref Buf outBuf)
    {
        const(char)[] data = buf.data;
        sort!((a, b) {
            if (a.region != b.region)
                return a.region < b.region;
            if (a.y != b.y)
                return a.y < b.y;
            if (a.x != b.x)
                return a.x < b.x;
            if (a.kind != b.kind)
                return a.kind < b.kind;
            return data[a.off .. a.off + a.len] < data[b.off .. b.off + b.len];
        })(items);
        foreach (it; items)
        {
            outBuf.put(data[it.off .. it.off + it.len]);
            outBuf.put('\n');
        }
    }
}

/// The document body: a gap buffer of mutable line buffers.
module textbuffer.lines;

import core.stdc.string : memchr, memcpy, memmove;
import std.array : uninitializedArray;

import textbuffer.position;
import textbuffer.vec;

/// A mutable, growable line of text (no newline characters inside).
struct Line
{
    private char[] data;
    private size_t len;

    /// Creates a line holding a copy of `s`, with no spare capacity.
    static Line from(const(char)[] s) nothrow
    {
        Line l;
        if (s.length)
        {
            l.data = uninitializedArray!(char[])(s.length);
            memcpy(l.data.ptr, s.ptr, s.length);
            l.len = s.length;
        }
        return l;
    }

    /// Number of characters.
    size_t length() const pure nothrow @nogc @safe { return len; }

    /// The characters. Invalidated by the next modification of the line.
    const(char)[] view() const pure nothrow @nogc @safe { return data[0 .. len]; }

    private void grow(size_t need) nothrow
    {
        size_t cap = data.length * 2;
        if (cap < need) cap = need;
        auto fresh = uninitializedArray!(char[])(cap);
        if (len)
            memcpy(fresh.ptr, data.ptr, len);
        data = fresh;
    }

    /// Appends `s` to the line.
    void append(const(char)[] s) nothrow @trusted
    {
        if (s.length == 0)
            return;
        if (len + s.length > data.length)
            grow(len + s.length);
        memcpy(data.ptr + len, s.ptr, s.length);
        len += s.length;
    }

    /// Cuts the line to its first `n` characters.
    void truncate(size_t n) pure nothrow @nogc @safe
    {
        assert(n <= len);
        len = n;
    }

    /// Replaces columns `[a, b)` by `ins`. `ins` must not alias the line.
    void splice(size_t a, size_t b, const(char)[] ins) nothrow @trusted
    {
        assert(a <= b && b <= len);
        immutable newLen = len - (b - a) + ins.length;
        immutable tail = len - b;
        if (newLen > data.length)
        {
            size_t cap = data.length * 2;
            if (cap < newLen) cap = newLen;
            auto fresh = uninitializedArray!(char[])(cap);
            if (a) memcpy(fresh.ptr, data.ptr, a);
            if (ins.length) memcpy(fresh.ptr + a, ins.ptr, ins.length);
            if (tail) memcpy(fresh.ptr + a + ins.length, data.ptr + b, tail);
            data = fresh;
        }
        else
        {
            if (tail && ins.length != b - a)
                memmove(data.ptr + a + ins.length, data.ptr + b, tail);
            if (ins.length)
                memcpy(data.ptr + a, ins.ptr, ins.length);
        }
        len = newLen;
    }
}

/// The lines of a document, stored as a gap buffer of `Line` slots.
///
/// Logical line `i` lives in slot `i` when `i < gapStart` and in slot
/// `i + gapLen` otherwise. Edits that change the number of lines move the gap
/// to the edited place first, so a run of edits at ascending (or descending)
/// line numbers moves each slot at most once overall.
final class LineStore
{
    private Line[] slots;
    private size_t gapStart;
    private size_t gapLen;
    private Vec!Line pending;

    /// Creates a document of one empty line.
    this()
    {
        this(null);
    }

    /// Creates a document from the given lines (copied). An empty list gives
    /// a single empty line.
    this(const(char)[][] initial)
    {
        immutable n = initial.length ? initial.length : 1;
        slots = new Line[](n + 16);
        foreach (i, s; initial)
            slots[i] = Line.from(s);
        gapStart = n;
        gapLen = slots.length - n;
    }

    /// Number of lines (at least 1).
    size_t length() const pure nothrow @nogc @safe { return slots.length - gapLen; }

    /// Line `i`, for reading.
    ref const(Line) opIndex(size_t i) const pure nothrow @nogc @safe
    {
        return slots[i < gapStart ? i : i + gapLen];
    }

    private ref Line at(size_t i) pure nothrow @nogc @safe
    {
        return slots[i < gapStart ? i : i + gapLen];
    }

    /// Length of line `i`.
    size_t lineLength(size_t i) const pure nothrow @nogc @safe
    {
        return this[i].length;
    }

    /// Appends the document text (lines joined by `'\n'`) to `output`.
    void writeText(ref CharBuf output) const nothrow
    {
        foreach (i; 0 .. length)
        {
            output.put(this[i].view);
            if (i + 1 < length)
                output.put('\n');
        }
    }

    /// Appends the text between `s` and `e` (`s <= e`) to `output`.
    void extract(Pos s, Pos e, ref CharBuf output) const nothrow
    {
        if (s == e)
            return;
        if (s.line == e.line)
        {
            output.put(this[s.line].view[s.col .. e.col]);
            return;
        }
        output.put(this[s.line].view[s.col .. $]);
        output.put('\n');
        foreach (i; s.line + 1 .. e.line)
        {
            output.put(this[i].view);
            output.put('\n');
        }
        output.put(this[e.line].view[0 .. e.col]);
    }

    /// Replaces the text between `s` and `e` (`s <= e`) by `text` and returns
    /// the position just after the inserted text. `text` may contain newlines
    /// and must not alias the document.
    Pos splice(Pos s, Pos e, const(char)[] text) @trusted
    {
        const nl = text.length ? cast(const(char)*) memchr(text.ptr, '\n', text.length) : null;
        if (nl is null)
        {
            if (s.line == e.line)
            {
                at(s.line).splice(s.col, e.col, text);
            }
            else
            {
                auto first = &at(s.line);
                first.truncate(s.col);
                first.append(text);
                first.append(this[e.line].view[e.col .. $]);
                replaceLines(s.line + 1, e.line - s.line, null);
            }
            return Pos(s.line, s.col + cast(int) text.length);
        }

        // Several pieces: p0 \n p1 \n ... \n p(k-1).
        pending.clear();
        auto rest = text;
        // Skip piece 0 (appended to the first line below).
        immutable p0len = nl - text.ptr;
        const p0 = text[0 .. p0len];
        rest = text[p0len + 1 .. $];
        while (true)
        {
            auto q = rest.length ? cast(const(char)*) memchr(rest.ptr, '\n', rest.length) : null;
            if (q is null)
                break;
            immutable plen = q - rest.ptr;
            pending.put(Line.from(rest[0 .. plen]));
            rest = rest[plen + 1 .. $];
        }
        // `rest` is the last piece; it receives the suffix of the end line.
        Line last = Line.from(rest);
        last.append(this[e.line].view[e.col .. $]);
        pending.put(last);

        auto first = &at(s.line);
        first.truncate(s.col);
        first.append(p0);

        replaceLines(s.line + 1, e.line - s.line, pending[]);
        immutable inserted = pending.length;
        pending.clear();
        return Pos(s.line + cast(int) inserted, cast(int) rest.length);
    }

    /// Removes `removeCount` lines starting at `first` and inserts `ins` there.
    private void replaceLines(size_t first, size_t removeCount, Line[] ins) nothrow
    {
        if (removeCount == ins.length)
        {
            foreach (i, ref l; ins)
                at(first + i) = l;
            return;
        }
        moveGap(first);
        foreach (i; 0 .. removeCount)
            slots[gapStart + gapLen + i] = Line.init;
        gapLen += removeCount;
        if (gapLen < ins.length)
            growGap(ins.length);
        slots[gapStart .. gapStart + ins.length] = ins[];
        gapStart += ins.length;
        gapLen -= ins.length;
    }

    private void moveGap(size_t to) nothrow @trusted
    {
        if (to == gapStart)
            return;
        if (gapLen != 0)
        {
            if (to < gapStart)
                memmove(slots.ptr + to + gapLen, slots.ptr + to, (gapStart - to) * Line.sizeof);
            else
                memmove(slots.ptr + gapStart, slots.ptr + gapStart + gapLen, (to - gapStart) * Line.sizeof);
        }
        gapStart = to;
    }

    private void growGap(size_t need) nothrow
    {
        immutable count = length;
        immutable tail = slots.length - gapStart - gapLen;
        size_t total = slots.length * 2;
        if (total < count + need + 16)
            total = count + need + 16;
        auto fresh = new Line[](total);
        fresh[0 .. gapStart] = slots[0 .. gapStart];
        fresh[total - tail .. total] = slots[gapStart + gapLen .. $];
        slots = fresh;
        gapLen = total - count;
    }
}

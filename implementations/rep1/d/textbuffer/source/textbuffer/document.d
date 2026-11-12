/// The document: an array of lines with splice-style replacement.
module textbuffer.document;

import core.stdc.string : memmove;
import std.algorithm.comparison : max, min;
import std.array : appender, uninitializedArray;
import std.string : indexOf;

import textbuffer.line;
import textbuffer.pos;

/// The line structure of a piece of text: how many newlines it holds and the
/// length of the text after the last one. Used to find where inserted text ends.
struct TextShape
{
    /// Number of `'\n'` characters.
    size_t newlines;
    /// Characters after the last newline (or all characters if there is none).
    size_t lastLineLength;

    /// Computes the shape of `text`.
    static TextShape of(const(char)[] text) @safe pure nothrow @nogc
    {
        TextShape r;
        size_t lastStart = 0;
        foreach (i, ch; text)
            if (ch == '\n')
            {
                ++r.newlines;
                lastStart = i + 1;
            }
        r.lastLineLength = text.length - lastStart;
        return r;
    }

    /// The position just after text of this shape inserted at `start`.
    Pos endFrom(Pos start) const @safe pure nothrow @nogc
    {
        if (newlines == 0)
            return Pos(start.line, cast(int)(start.col + lastLineLength));
        return Pos(cast(int)(start.line + newlines), cast(int) lastLineLength);
    }
}

/// The position just after `text` inserted at `start`.
Pos endOfText(Pos start, const(char)[] text) @safe pure nothrow @nogc
{
    return TextShape.of(text).endFrom(start);
}

/// A document: `L ≥ 1` lines of printable ASCII, joined by newlines.
///
/// Replacing a range costs O(ℓ + m) within a line, plus O(L) when lines are
/// added or removed. The lines live in a gap buffer: the free gap follows the
/// most recent line insertion or removal, so a run of edits that move through
/// the document in order (as a multi-cursor edit does) shifts each line at most
/// once instead of once per edit.
final class Document
{
    private Line[] store;    // lines [0, gapStart) ~ gap ~ lines [gapEnd, store.length)
    private size_t gapStart;
    private size_t gapEnd;

    /// Creates a document from its lines; no lines means one empty line.
    this(const(char)[][] lines = null) @safe pure nothrow
    {
        immutable n = max(lines.length, 1);
        store = new Line[](n);
        foreach (i, l; lines)
            store[i] = Line(l);
        if (lines.length == 0)
            store[0] = Line("");
        gapStart = gapEnd = n;
    }

    private size_t count() const @safe pure nothrow @nogc
    {
        return store.length - (gapEnd - gapStart);
    }

    /// The storage slot of logical line `i`.
    private ref inout(Line) at(size_t i) inout @safe pure nothrow @nogc
    {
        return store[i < gapStart ? i : i + (gapEnd - gapStart)];
    }

    /// Number of lines (always at least 1).
    size_t lineCount() const @safe pure nothrow @nogc
    {
        return count;
    }

    /// Text of line `i`, valid until the next mutation.
    const(char)[] line(size_t i) const @safe pure nothrow @nogc
    in (i < count)
    {
        return at(i).text;
    }

    /// Length of line `i`.
    size_t lineLength(size_t i) const @safe pure nothrow @nogc
    in (i < count)
    {
        return at(i).length;
    }

    /// The position at the very end of the document.
    Pos end() const @safe pure nothrow @nogc
    {
        return Pos(cast(int)(count - 1), cast(int) at(count - 1).length);
    }

    /// Clamps arbitrary integers to a valid position: first the line, then the column.
    Pos clamp(long line, long col) const @safe pure nothrow @nogc
    {
        immutable l = cast(int) min(max(line, 0L), cast(long) count - 1);
        immutable c = cast(int) min(max(col, 0L), cast(long) at(l).length);
        return Pos(l, c);
    }

    /// Whether `p` is a valid position of this document.
    bool isValid(Pos p) const @safe pure nothrow @nogc
    {
        return p.line >= 0 && p.line < count && p.col >= 0 && p.col <= at(p.line).length;
    }

    /// The text between two positions, with `'\n'` joining lines. Requires `from <= to`.
    string slice(Pos from, Pos to) const @safe pure
    in (from <= to && isValid(from) && isValid(to))
    {
        if (from.line == to.line)
            return at(from.line).text[from.col .. to.col].idup;
        auto app = appender!string();
        app.put(at(from.line).text[from.col .. $]);
        foreach (i; from.line + 1 .. to.line)
        {
            app.put('\n');
            app.put(at(i).text);
        }
        app.put('\n');
        app.put(at(to.line).text[0 .. to.col]);
        return app[];
    }

    /// The whole text of the document, lines joined by newlines.
    string text() const @safe pure
    {
        return slice(Pos(0, 0), end());
    }

    /// Replaces the text between `from` and `to` (`from <= to`) by `ins`.
    /// `ins` may contain newlines and must not alias the document.
    void replace(Pos from, Pos to, const(char)[] ins) @trusted pure nothrow
    in (from <= to && isValid(from) && isValid(to))
    {
        immutable shape = TextShape.of(ins);
        if (shape.newlines == 0)
        {
            if (from.line == to.line)
            {
                at(from.line).replace(from.col, to.col, ins);
                return;
            }
            // Join: head of the first line + text + tail of the last line.
            auto first = &at(from.line);
            first.truncate(from.col);
            first.append(ins);
            first.append(at(to.line).text[to.col .. $]);
            resizeGap(from.line + 1, to.line + 1, 0);
            return;
        }

        // The new last line is built first: it copies the tail of the old last
        // line, which may be the very line we are about to truncate.
        immutable lastStart = ins.length - shape.lastLineLength;
        auto last = Line(ins[lastStart .. $], at(to.line).text[to.col .. $]);

        immutable firstNl = ins.indexOf('\n');
        auto first = &at(from.line);
        first.truncate(from.col);
        first.append(ins[0 .. firstNl]);

        resizeGap(from.line + 1, to.line + 1, shape.newlines);
        size_t at = from.line + 1;
        size_t pos = firstNl + 1;
        foreach (_; 1 .. shape.newlines)
        {
            immutable nl = pos + ins[pos .. $].indexOf('\n');
            this.at(at++) = Line(ins[pos .. nl]);
            pos = nl + 1;
        }
        this.at(at) = last;
    }

    /// Replaces the logical lines `[from, to)` by `n` fresh (empty) lines
    /// `[from, from + n)`, leaving the gap right after them.
    private void resizeGap(size_t from, size_t to, size_t n) @trusted pure nothrow
    {
        immutable oldCount = count;
        moveGap(from);
        // Drop the removed lines: they now sit right after the gap.
        store[gapEnd .. gapEnd + (to - from)] = Line.init;
        gapEnd += to - from;
        if (gapEnd - gapStart < n)
        {
            // Grow, keeping as much free room as there are lines.
            immutable newCount = oldCount - (to - from) + n;
            immutable tail = store.length - gapEnd;
            auto ns = new Line[](newCount + max(newCount, 16));
            ns[0 .. gapStart] = store[0 .. gapStart];
            immutable ne = ns.length - tail;
            ns[ne .. $] = store[gapEnd .. $];
            store = ns;
            gapEnd = ne;
        }
        gapStart += n;  // the new slots hold Line.init (empty lines)
    }

    /// Moves the gap so that it starts at logical line `pos`.
    private void moveGap(size_t pos) @trusted pure nothrow
    {
        immutable gapLen = gapEnd - gapStart;
        if (pos < gapStart)
        {
            immutable k = gapStart - pos;
            memmove(store.ptr + pos + gapLen, store.ptr + pos, k * Line.sizeof);
            store[pos .. pos + min(k, gapLen)] = Line.init;
            gapStart = pos;
            gapEnd = pos + gapLen;
        }
        else if (pos > gapStart)
        {
            immutable k = pos - gapStart;
            memmove(store.ptr + gapStart, store.ptr + gapEnd, k * Line.sizeof);
            immutable clearFrom = max(gapEnd, gapStart + k);
            store[clearFrom .. gapEnd + k] = Line.init;
            gapStart += k;
            gapEnd += k;
        }
    }
}

@safe pure unittest
{
    auto d = new Document(["hello", "world"]);
    assert(d.lineCount == 2);
    assert(d.text == "hello\nworld");
    assert(d.end == Pos(1, 5));
    assert(d.clamp(99, 99) == Pos(1, 5));
    assert(d.clamp(0, 99) == Pos(0, 5));

    d.replace(Pos(0, 5), Pos(0, 5), ", there");
    assert(d.line(0) == "hello, there");
    d.replace(Pos(0, 5), Pos(1, 0), "");  // join lines
    assert(d.text == "helloworld");
    d.replace(Pos(0, 2), Pos(0, 2), "A\nB\nC");
    assert(d.text == "heA\nB\nClloworld");
    assert(d.lineCount == 3);
    d.replace(Pos(0, 1), Pos(2, 1), "XY\nZ");
    assert(d.text == "hXY\nZlloworld");
    assert(d.slice(Pos(0, 2), Pos(1, 2)) == "Y\nZl");
}

@safe pure unittest
{
    auto d = new Document;
    assert(d.lineCount == 1 && d.text == "");
    d.replace(Pos(0, 0), Pos(0, 0), "\n\n");
    assert(d.lineCount == 3);
    d.replace(Pos(0, 0), Pos(2, 0), "");
    assert(d.lineCount == 1 && d.text == "");
}

@safe pure nothrow @nogc unittest
{
    immutable s = TextShape.of("ab\ncde\nf");
    assert(s.newlines == 2 && s.lastLineLength == 1);
    assert(s.endFrom(Pos(4, 7)) == Pos(6, 1));
    assert(endOfText(Pos(1, 2), "xyz") == Pos(1, 5));
}

@safe unittest
{
    // Randomised comparison with a plain string model; exercises the gap buffer
    // moving in both directions and growing.
    import std.random : Random, uniform;
    import std.algorithm.searching : count;

    auto rng = Random(99);
    auto d = new Document(["alpha", "beta", "", "delta"]);
    string model = "alpha\nbeta\n\ndelta";

    size_t offsetOf(Pos p)
    {
        size_t off = p.col;
        foreach (i; 0 .. p.line)
            off += d.line(i).length + 1;
        return off;
    }

    foreach (step; 0 .. 4000)
    {
        immutable a = d.clamp(uniform(0, cast(int) d.lineCount + 2, rng), uniform(0, 12, rng));
        immutable b = d.clamp(uniform(0, cast(int) d.lineCount + 2, rng), uniform(0, 12, rng));
        immutable from = a < b ? a : b, to = a < b ? b : a;
        string ins;
        foreach (_; 0 .. uniform(0, 6, rng))
            ins ~= "xyz\n"[uniform(0, 4, rng)];
        if (d.lineCount > 60 && uniform(0, 2, rng))
            ins = "";
        immutable fo = offsetOf(from), to_ = offsetOf(to);
        assert(d.slice(from, to) == model[fo .. to_]);
        model = model[0 .. fo] ~ ins ~ model[to_ .. $];
        d.replace(from, to, ins);
        assert(d.text == model);
        assert(d.lineCount == model.count('\n') + 1);
    }
}

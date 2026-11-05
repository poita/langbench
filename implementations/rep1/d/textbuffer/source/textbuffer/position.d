/// Document positions and text-shape helpers.
module textbuffer.position;

/// A location in the document: zero-based line and column.
///
/// Columns are character (= byte) indexes; `col == length of line` is the end
/// of that line. Positions order lexicographically by line, then column.
struct Pos
{
    int line;
    int col;

    int opCmp(const Pos o) const pure nothrow @nogc @safe
    {
        if (line != o.line)
            return line < o.line ? -1 : 1;
        return (col > o.col) - (col < o.col);
    }

    bool opEquals(const Pos o) const pure nothrow @nogc @safe
    {
        return line == o.line && col == o.col;
    }
}

/// The smaller of two positions.
Pos minPos(const Pos a, const Pos b) pure nothrow @nogc @safe
{
    return b < a ? b : a;
}

/// The larger of two positions.
Pos maxPos(const Pos a, const Pos b) pure nothrow @nogc @safe
{
    return a < b ? b : a;
}

/// The geometry of a piece of text: how it moves a position that is placed
/// just before it to the position just after it.
struct TextShape
{
    /// Number of `'\n'` characters.
    uint newlines;
    /// Number of characters after the last newline (all of them if none).
    uint lastLineLength;
    /// Total number of characters.
    uint length;
}

/// Measures `text`.
TextShape shapeOf(const(char)[] text) pure nothrow @nogc @trusted
{
    TextShape sh;
    sh.length = cast(uint) text.length;
    uint last = 0;
    foreach (i, ch; text)
    {
        if (ch == '\n')
        {
            ++sh.newlines;
            last = cast(uint) i + 1;
        }
    }
    sh.lastLineLength = sh.length - last;
    return sh;
}

/// The position reached by writing text of shape `sh` starting at `p`.
Pos advance(const Pos p, const TextShape sh) pure nothrow @nogc @safe
{
    if (sh.newlines == 0)
        return Pos(p.line, p.col + cast(int) sh.length);
    return Pos(p.line + cast(int) sh.newlines, cast(int) sh.lastLineLength);
}

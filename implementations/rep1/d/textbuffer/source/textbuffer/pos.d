/// Document positions.
module textbuffer.pos;

/// A position in a document: a 0-based line and a 0-based column.
///
/// Since every line holds printable ASCII only, a column is both a character
/// index and a byte index. A column equal to the line length denotes the end
/// of that line. Positions are ordered lexicographically (line, then column).
struct Pos
{
    /// 0-based line index.
    int line;
    /// 0-based column within the line.
    int col;

    /// Lexicographic ordering.
    int opCmp(const Pos other) const @safe pure nothrow @nogc
    {
        if (line != other.line)
            return line < other.line ? -1 : 1;
        if (col != other.col)
            return col < other.col ? -1 : 1;
        return 0;
    }

    /// Equality (needed alongside `opCmp`).
    bool opEquals(const Pos other) const @safe pure nothrow @nogc
    {
        return line == other.line && col == other.col;
    }
}

@safe pure nothrow @nogc unittest
{
    assert(Pos(1, 5) < Pos(2, 0));
    assert(Pos(1, 5) > Pos(1, 4));
    assert(Pos(3, 3) == Pos(3, 3));
    assert(Pos(0, 9) <= Pos(0, 9));
}

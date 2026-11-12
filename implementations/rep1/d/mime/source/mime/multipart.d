/// Boundary scanning for multipart bodies.
module mime.multipart;

import mime.lines;

@safe:

/// The pieces of a multipart body.
struct Layout
{
    size_t preambleLength;        /// bytes before the first delimiter, less one LF
    const(ubyte)[][] children;    /// raw bytes of each child part
    bool hasEpilogue;             /// whether a close delimiter was seen
    size_t epilogueLength;        /// bytes after the close delimiter line
}

private enum Delim { none, open, close }

private Delim classify(const(ubyte)[] line, const(ubyte)[] boundary) pure nothrow @nogc
{
    const n = boundary.length;
    if (line.length < n + 2 || line[0] != '-' || line[1] != '-' || line[2 .. 2 + n] != boundary)
        return Delim.none;
    auto rest = line[2 + n .. $];
    Delim kind = Delim.open;
    if (rest.length >= 2 && rest[0] == '-' && rest[1] == '-')
    {
        kind = Delim.close;
        rest = rest[2 .. $];
    }
    foreach (c; rest)
        if (c != ' ' && c != '\t')
            return Delim.none;
    return kind;
}

/// Splits `data` (line endings already normalised) at the delimiter lines
/// of `boundary` (a non-empty UTF-8 byte string).
Layout splitMultipart(const(ubyte)[] data, const(ubyte)[] boundary) pure nothrow
{
    Layout lay;
    bool seenFirst = false, closed = false;
    size_t childStart = 0;

    static size_t trimmedEnd(const(ubyte)[] d, size_t from, size_t end) pure nothrow @nogc
    {
        return (end > from && d[end - 1] == '\n') ? end - 1 : end;
    }

    size_t pos = 0;
    while (pos < data.length)
    {
        const ln = nextLine(data, pos);
        const kind = classify(data[ln.start .. ln.end], boundary);
        if (kind != Delim.none)
        {
            if (!seenFirst)
            {
                seenFirst = true;
                lay.preambleLength = ln.start > 0 ? ln.start - 1 : 0;
            }
            else
                lay.children ~= data[childStart .. trimmedEnd(data, childStart, ln.start)];
            if (kind == Delim.close)
            {
                closed = true;
                lay.hasEpilogue = true;
                lay.epilogueLength = data.length - ln.next;
                break;
            }
            childStart = ln.next;
        }
        pos = ln.next;
    }
    if (!seenFirst)
        lay.preambleLength = data.length;
    else if (!closed)
        lay.children ~= data[childStart .. trimmedEnd(data, childStart, data.length)];
    return lay;
}

pure nothrow unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    auto l = splitMultipart(u("pre\n--X\na\n--X\n\n--X--  \nepi\n"), u("X"));
    assert(l.preambleLength == 3);
    assert(l.children == [u("a"), u("")]);
    assert(l.hasEpilogue && l.epilogueLength == 4);

    l = splitMultipart(u("no delimiter\n"), u("X"));
    assert(l.preambleLength == 13 && l.children.length == 0 && !l.hasEpilogue);

    l = splitMultipart(u("--X\none\n--X\ntwo\n"), u("X"));
    assert(l.preambleLength == 0 && l.children == [u("one"), u("two")] && !l.hasEpilogue);

    l = splitMultipart(u("--X--\nrest"), u("X"));
    assert(l.children.length == 0 && l.hasEpilogue && l.epilogueLength == 4);

    l = splitMultipart(u("--X\n--X\n--XY\n--X"), u("X"));
    assert(l.children == [u(""), u("--XY"), u("")]);
}

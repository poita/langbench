/**
 * Parsing of the textual request format: a mode line (`diff` or `patch`),
 * then two count-prefixed blocks of lines.
 *
 * Lines are taken verbatim between `'\n'` bytes. For robustness a trailing
 * `'\r'` on any line is dropped (`\r\n` input), a missing final newline is
 * accepted, trailing spaces/tabs on count and mode lines are ignored, and
 * extra empty lines after the last block are ignored.
 */
module myersdiff.parse;

import myersdiff.intern : Line;

/// Which task a request asks for.
enum Mode { diff, patch }

/// A parsed request. For `Mode.diff`, `second` is file B; for `Mode.patch`
/// it is the raw script lines. All slices point into the original input.
struct Request
{
    Mode mode;
    const(Line)[] first;
    const(Line)[] second;
}

/// Thrown for malformed input.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Parses a complete request from `input`.
Request parseRequest(Line input) @safe pure
{
    auto cur = Cursor(input);
    Request r;
    const mode = trimBlanks(cur.next("mode line"));
    if (mode == "diff")
        r.mode = Mode.diff;
    else if (mode == "patch")
        r.mode = Mode.patch;
    else
        throw new ParseException("unknown mode");
    r.first = readBlock(cur, "first block");
    r.second = readBlock(cur, "second block");
    return r;
}

private:

struct Cursor
{
    Line text;
    size_t pos;
    bool phantomUsed;

    /// Next line without its terminator. At end of input, one empty line is
    /// supplied (a final empty line whose newline was omitted); after that
    /// reading is an error.
    Line next(string what) @safe pure
    {
        if (pos >= text.length)
        {
            if (phantomUsed)
                throw new ParseException("unexpected end of input in " ~ what);
            phantomUsed = true;
            return text[$ .. $];
        }
        size_t end = pos;
        while (end < text.length && text[end] != '\n')
            ++end;
        auto line = text[pos .. end];
        pos = end < text.length ? end + 1 : end;
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        return line;
    }
}

Line trimBlanks(Line s) @safe pure nothrow @nogc
{
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    return s;
}

size_t parseCount(Line line) @safe pure
{
    line = trimBlanks(line);
    if (line.length == 0 || line.length > 9)
        throw new ParseException("bad count line");
    size_t n;
    foreach (c; line)
    {
        if (c < '0' || c > '9')
            throw new ParseException("bad count line");
        n = n * 10 + (c - '0');
    }
    return n;
}

const(Line)[] readBlock(ref Cursor cur, string what) @safe pure
{
    const n = parseCount(cur.next(what));
    auto lines = new Line[n];
    foreach (ref l; lines)
        l = cur.next(what);
    return lines;
}

unittest
{
    auto r = parseRequest("diff\n2\na\n\n1\n  x \n");
    assert(r.mode == Mode.diff);
    assert(r.first == ["a", ""]);
    assert(r.second == ["  x "]);
}

unittest // leniencies
{
    auto r = parseRequest("patch \r\n1 \r\nq\r\n2\r\n q\r\n+\r\n\n\n");
    assert(r.mode == Mode.patch);
    assert(r.first == ["q"]);
    assert(r.second == [" q", "+"]);
    // missing final newline; empty final line omitted
    assert(parseRequest("diff\n0\n1\nz").second == ["z"]);
    assert(parseRequest("diff\n0\n1\n").second == [""]);
}

unittest // lines that look like counts or tags
{
    auto r = parseRequest("patch\n2\n5\n-\n3\n+-x\n+5\n  \n");
    assert(r.first == ["5", "-"]);
    assert(r.second == ["+-x", "+5", "  "]);
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!ParseException(parseRequest(""));
    assertThrown!ParseException(parseRequest("bogus\n0\n0\n"));
    assertThrown!ParseException(parseRequest("diff\nx\n"));
    assertThrown!ParseException(parseRequest("diff\n3\na\n"));
}

/// Parsing and rendering of the line-oriented query format `<ecl> <mask> <text>`.
module qrcode.query;

import qrcode.encoder;
import qrcode.tables;

/// A parsed query line.
struct Query
{
    /// Error correction level.
    Ecl ecl;
    /// Mask 0..7, or `autoMask`.
    int mask;
    /// Payload bytes (UTF-8, taken verbatim).
    const(ubyte)[] text;
}

/// Raised for a malformed query line.
class QueryFormatException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Parses one query line (without its line terminator).
/// Throws `QueryFormatException` if the line is not `<L|M|Q|H> <0..7|auto> <text>`.
Query parseQuery(const(ubyte)[] line) @safe pure
{
    Query q;
    if (line.length < 5 || line[1] != ' ' || !parseEcl(cast(char) line[0], q.ecl))
        throw new QueryFormatException("expected '<L|M|Q|H> <mask> <text>'");
    const rest = line[2 .. $];
    size_t sp = 0;
    while (sp < rest.length && rest[sp] != ' ')
        sp++;
    if (sp == rest.length || sp + 1 == rest.length)
        throw new QueryFormatException("missing mask or text");
    const maskWord = rest[0 .. sp];
    if (maskWord.length == 1 && maskWord[0] >= '0' && maskWord[0] <= '7')
        q.mask = maskWord[0] - '0';
    else if (maskWord == cast(const(ubyte)[]) "auto")
        q.mask = autoMask;
    else
        throw new QueryFormatException("mask must be 0..7 or 'auto'");
    q.text = rest[sp + 1 .. $];
    return q;
}

/// Splits input into lines on `\n` (a final newline is optional; a trailing `\r` is dropped) and parses each.
Query[] parseQueries(const(ubyte)[] input) @safe pure
{
    Query[] result;
    while (input.length)
    {
        size_t e = 0;
        while (e < input.length && input[e] != '\n')
            e++;
        auto line = input[0 .. e];
        input = e < input.length ? input[e + 1 .. $] : input[$ .. $];
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        result ~= parseQuery(line);
    }
    return result;
}

/// Encodes a query and renders the output block (header, rows and the blank separator line).
string renderQuery(const Query q) @safe pure
{
    return encode(q.text, q.ecl, q.mask).toText() ~ "\n";
}

@safe pure unittest
{
    auto q = parseQuery(cast(const(ubyte)[]) "Q auto hello world");
    assert(q.ecl == Ecl.quartile && q.mask == autoMask);
    assert(q.text == cast(const(ubyte)[]) "hello world");
    q = parseQuery(cast(const(ubyte)[]) "L 7 x");
    assert(q.ecl == Ecl.low && q.mask == 7);
}

@safe pure unittest
{
    import std.exception : assertThrown;
    foreach (bad; ["", "X 0 abc", "L 8 abc", "L auto", "L 0", "L0 abc", "L autox abc"])
        assertThrown!QueryFormatException(parseQuery(cast(const(ubyte)[]) bad));
}

@safe pure unittest
{
    auto qs = parseQueries(cast(const(ubyte)[]) "L 0 1\nH auto 2\r\nM 3 a b");
    assert(qs.length == 3 && qs[1].text == cast(const(ubyte)[]) "2" && qs[2].text == cast(const(ubyte)[]) "a b");
    assert(parseQueries([]).length == 0);
}

@safe pure unittest
{
    import std.algorithm : startsWith, endsWith;
    auto s = renderQuery(parseQuery(cast(const(ubyte)[]) "L auto 01234567"));
    assert(s.startsWith("version 1 mask 3\n#######."));
    assert(s.endsWith("#######.##.##..#...#.\n\n"));
}

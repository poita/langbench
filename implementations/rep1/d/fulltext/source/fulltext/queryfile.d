/**
 * Parsing of `queries.txt`: one query per line, `#` comments, blank lines and
 * `%k N` directives that set the result limit for the queries after them.
 */
module fulltext.queryfile;

import fulltext.analysis : isSpace;

@safe:

/// Result limit in force before any `%k` directive.
enum size_t defaultK = 10;

/// A query line together with its number and result limit.
struct QueryLine
{
    /// 1-based number (directives, comments and blank lines are not counted).
    uint number;
    /// The query text with surrounding whitespace removed.
    string text;
    /// Maximum number of hits to return.
    size_t k;
}

/// Strips leading and trailing whitespace (the seven specified code points).
string stripSpace(string s) pure
{
    import std.utf : decode;

    size_t b = 0, e = s.length;
    while (b < e)
    {
        size_t j = b;
        if (!isSpace(decode(s, j)))
            break;
        b = j;
    }
    while (e > b)
    {
        // U+00A0 is C2 A0 in UTF-8; the other six are single bytes.
        if (e - b >= 2 && s[e - 2] == 0xC2 && s[e - 1] == 0xA0)
            e -= 2;
        else if (s[e - 1] < 0x80 && isSpace(s[e - 1]))
            e -= 1;
        else
            break;
    }
    return s[b .. e];
}

/// If `line` is a `%k N` directive, stores N in `k` and returns true.
bool parseKDirective(string line, out size_t k) pure nothrow @nogc
{
    if (line.length < 3 || line[0] != '%' || line[1] != 'k')
        return false;
    size_t i = 2;
    immutable ws = i;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        i++;
    if (i == ws)
        return false;
    immutable ds = i;
    size_t value = 0;
    while (i < line.length && line[i] >= '0' && line[i] <= '9')
    {
        immutable digit = line[i] - '0';
        value = value > (size_t.max - digit) / 10 ? size_t.max : value * 10 + digit;
        i++;
    }
    if (i == ds)
        return false;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        i++;
    if (i != line.length)
        return false;
    k = value;
    return true;
}

/// Parses the contents of a queries file.
QueryLine[] parseQueryFile(string contents) pure
{
    import std.algorithm : splitter;

    QueryLine[] result;
    size_t k = defaultK;
    uint number = 0;
    foreach (raw; contents.splitter('\n'))
    {
        auto line = stripSpace(raw);
        if (line.length == 0 || line[0] == '#')
            continue;
        size_t newK;
        if (parseKDirective(line, newK))
        {
            k = newK;
            continue;
        }
        result ~= QueryLine(++number, line, k);
    }
    return result;
}

unittest
{
    auto q = parseQueryFile("fox\n# comment\n\n%k 3\n  quick brown \t\n%k\t20  \nlast");
    assert(q.length == 3);
    assert(q[0] == QueryLine(1, "fox", 10));
    assert(q[1] == QueryLine(2, "quick brown", 3));
    assert(q[2] == QueryLine(3, "last", 20));
}

unittest
{
    size_t k;
    assert(parseKDirective("%k 5", k) && k == 5);
    assert(parseKDirective("%k \t 007 ", k) && k == 7);
    assert(!parseKDirective("%k", k));
    assert(!parseKDirective("%k5", k));
    assert(!parseKDirective("%k x", k));
    assert(!parseKDirective("%k 5 6", k));
    assert(!parseKDirective("% k 5", k));
    assert(!parseKDirective("%K 5", k));
}

unittest
{
    assert(stripSpace("  a b\r\n") == "a b");
    assert(stripSpace("  ") == "");
    // CRLF and a missing final newline
    assert(parseQueryFile("a\r\nb").length == 2);
    assert(parseQueryFile("").length == 0);
    // a line with only a NBSP is blank
    assert(parseQueryFile(" \n").length == 0);
}

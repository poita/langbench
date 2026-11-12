/**
 * A reader for the small TOML subset used by site configuration and front
 * matter.
 *
 * A document is a sequence of blank lines, comment lines and assignments
 * `key = value`.  Values are basic strings, integers, booleans and arrays of
 * strings.  There are no tables, dotted keys or multi-line values.
 *
 * Example:
 * ---
 * auto doc = parseToml("title = \"Hi\"\nn = 3 # comment\n");
 * assert(doc["title"].str == "Hi");
 * assert(doc["n"].integer == 3);
 * ---
 */
module sitegen.toml;

import std.array : Appender;
import std.utf : encode;

/// The error thrown for malformed input.
class TomlException : Exception
{
    ///
    this(string message, size_t lineNumber, string file = __FILE__, size_t line = __LINE__)
    {
        import std.conv : to;

        super("line " ~ lineNumber.to!string ~ ": " ~ message, file, line);
    }
}

/// The kinds of TOML value.
enum TomlKind : ubyte
{
    string_,
    integer,
    boolean,
    array,
}

/// A TOML value.
struct TomlValue
{
    TomlKind kind;
    string str;
    long integer;
    bool boolean;
    string[] array;
}

/// One `key = value` assignment.
struct TomlEntry
{
    string key;
    TomlValue value;
}

/// A parsed document: its assignments in file order.
struct TomlDocument
{
    TomlEntry[] entries;

    /// The value of `key`; throws `TomlException` if it is absent.
    TomlValue opIndex(string key) const
    {
        foreach (ref e; entries)
            if (e.key == key) return cast(TomlValue) e.value;
        throw new TomlException("missing key '" ~ key ~ "'", 0);
    }

    /// Whether `key` is present.
    bool contains(string key) const
    {
        foreach (ref e; entries)
            if (e.key == key) return true;
        return false;
    }

    /// Looks `key` up, returning whether it is present.
    bool get(string key, out TomlValue value) const
    {
        foreach (ref e; entries)
        {
            if (e.key == key)
            {
                value = cast(TomlValue) e.value;
                return true;
            }
        }
        return false;
    }
}

private bool isBlank(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t';
}

private bool isKeyChar(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '-';
}

private int hexDigit(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/**
 * Parses a TOML-subset document.
 *
 * Throws: `TomlException` if a line is malformed.
 */
TomlDocument parseToml(string text)
{
    TomlDocument doc;
    size_t lineNo = 0;
    size_t pos = 0;
    while (pos <= text.length)
    {
        size_t eol = pos;
        while (eol < text.length && text[eol] != '\n') eol++;
        lineNo++;
        parseLine(text[pos .. eol], lineNo, doc);
        pos = eol + 1;
    }
    return doc;
}

private void parseLine(string line, size_t lineNo, ref TomlDocument doc)
{
    size_t i = 0;
    const n = line.length;
    while (i < n && isBlank(line[i])) i++;
    if (i == n || line[i] == '#') return;

    const keyStart = i;
    while (i < n && isKeyChar(line[i])) i++;
    if (i == keyStart) throw new TomlException("expected a key", lineNo);
    const key = line[keyStart .. i];
    while (i < n && isBlank(line[i])) i++;
    if (i >= n || line[i] != '=') throw new TomlException("expected '='", lineNo);
    i++;
    while (i < n && isBlank(line[i])) i++;
    if (i >= n) throw new TomlException("missing value", lineNo);

    TomlValue v;
    if (line[i] == '"')
    {
        v.kind = TomlKind.string_;
        v.str = parseString(line, i, lineNo);
    }
    else if (line[i] == '[')
    {
        v.kind = TomlKind.array;
        i++;
        while (true)
        {
            while (i < n && isBlank(line[i])) i++;
            if (i >= n) throw new TomlException("unterminated array", lineNo);
            if (line[i] == ']')
            {
                i++;
                break;
            }
            if (line[i] != '"') throw new TomlException("expected a string", lineNo);
            v.array ~= parseString(line, i, lineNo);
            while (i < n && isBlank(line[i])) i++;
            if (i < n && line[i] == ',')
            {
                i++;
                continue;
            }
            if (i < n && line[i] == ']')
            {
                i++;
                break;
            }
            throw new TomlException("expected ',' or ']'", lineNo);
        }
    }
    else if (line[i] == 't' || line[i] == 'f')
    {
        v.kind = TomlKind.boolean;
        const rest = line[i .. $];
        if (rest.length >= 4 && rest[0 .. 4] == "true")
        {
            v.boolean = true;
            i += 4;
        }
        else if (rest.length >= 5 && rest[0 .. 5] == "false")
        {
            v.boolean = false;
            i += 5;
        }
        else
            throw new TomlException("bad value", lineNo);
    }
    else
    {
        v.kind = TomlKind.integer;
        const start = i;
        bool neg = false;
        if (line[i] == '-')
        {
            neg = true;
            i++;
        }
        const digitsStart = i;
        long value = 0;
        while (i < n && line[i] >= '0' && line[i] <= '9')
        {
            value = value * 10 + (line[i] - '0');
            i++;
        }
        if (i == digitsStart) throw new TomlException("bad value", lineNo);
        v.integer = neg ? -value : value;
    }

    while (i < n && isBlank(line[i])) i++;
    if (i < n && line[i] != '#') throw new TomlException("unexpected text after the value", lineNo);

    doc.entries ~= TomlEntry(key.idup, v);
}

/// Parses the basic string whose opening quote is at `line[i]`, leaving `i`
/// after the closing quote.
private string parseString(string line, ref size_t i, size_t lineNo)
{
    const n = line.length;
    i++;
    Appender!string o;
    while (true)
    {
        if (i >= n) throw new TomlException("unterminated string", lineNo);
        const c = line[i];
        if (c == '"')
        {
            i++;
            return o.data;
        }
        if (c != '\\')
        {
            o.put(c);
            i++;
            continue;
        }
        if (i + 1 >= n) throw new TomlException("unterminated string", lineNo);
        const e = line[i + 1];
        i += 2;
        switch (e)
        {
            case '"': o.put('"'); break;
            case '\\': o.put('\\'); break;
            case 'n': o.put('\n'); break;
            case 't': o.put('\t'); break;
            case 'r': o.put('\r'); break;
            case 'u':
                {
                    if (i + 4 > n) throw new TomlException("bad \\u escape", lineNo);
                    uint cp = 0;
                    foreach (k; 0 .. 4)
                    {
                        const h = hexDigit(line[i + k]);
                        if (h < 0) throw new TomlException("bad \\u escape", lineNo);
                        cp = cp * 16 + h;
                    }
                    i += 4;
                    char[4] buf;
                    const len = encode(buf, cast(dchar) cp);
                    o.put(buf[0 .. len]);
                }
                break;
            default:
                throw new TomlException("bad escape", lineNo);
        }
    }
}

unittest
{
    auto doc = parseToml(`# a comment
title  = "The \"Big\" Blog"        # trailing comment
posts_per_page = 5
draft = false
tags = ["one", "two",]
motto = "line one\nline two"
hash = "not # a comment"
neg = -44
e = "\u00e9t\u00E9"
empty = []
  indented = true
`);
    assert(doc.entries.length == 10);
    assert(doc["title"].str == `The "Big" Blog`);
    assert(doc["posts_per_page"].integer == 5);
    assert(!doc["draft"].boolean);
    assert(doc["tags"].array == ["one", "two"]);
    assert(doc["motto"].str == "line one\nline two");
    assert(doc["hash"].str == "not # a comment");
    assert(doc["neg"].integer == -44);
    assert(doc["e"].str == "été");
    assert(doc["empty"].array.length == 0);
    assert(doc["indented"].boolean);
    assert(doc.entries[0].key == "title" && doc.entries[9].key == "indented");
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!TomlException(parseToml("a = "));
    assertThrown!TomlException(parseToml("a = \"x"));
    assertThrown!TomlException(parseToml("a = 1 2"));
    assertThrown!TomlException(parseToml("= 1"));
    assertThrown!TomlException(parseToml("a = [\"x\" \"y\"]"));
    assertThrown!TomlException(parseToml("a = \"\\q\""));
}

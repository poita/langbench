/// Reader for the small TOML subset used by `site.toml` and front matter.
///
/// Supported: comments, blank lines and `key = value` lines where the value is
/// a basic string, an integer, a boolean or a one-line array of strings.
/// There are no tables, dotted keys or multi-line values.
module sitegen.toml;

import std.array : appender;
import std.conv : to;

/// The type of a `TomlValue`.
enum TomlKind
{
    string_,
    integer,
    boolean,
    array,
}

/// A parsed value.
struct TomlValue
{
    TomlKind kind;
    string str; /// for `string_`
    long integer; /// for `integer`
    bool boolean; /// for `boolean`
    string[] array; /// for `array`
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

    /// Pointer to the value of `key`, or null if absent.
    const(TomlValue)* find(string key) const pure nothrow @safe
    {
        foreach (ref e; entries)
            if (e.key == key)
                return &e.value;
        return null;
    }

    /// The string value of `key`, or `fallback` if the key is absent.
    /// Throws if the key holds another type.
    string getString(string key, string fallback = null) const
    {
        auto v = find(key);
        if (v is null)
            return fallback;
        if (v.kind != TomlKind.string_)
            throw new TomlException("key '" ~ key ~ "' must be a string");
        return v.str;
    }

    /// The integer value of `key`, or `fallback` if absent.
    long getInteger(string key, long fallback = 0) const
    {
        auto v = find(key);
        if (v is null)
            return fallback;
        if (v.kind != TomlKind.integer)
            throw new TomlException("key '" ~ key ~ "' must be an integer");
        return v.integer;
    }

    /// The boolean value of `key`, or `fallback` if absent.
    bool getBool(string key, bool fallback = false) const
    {
        auto v = find(key);
        if (v is null)
            return fallback;
        if (v.kind != TomlKind.boolean)
            throw new TomlException("key '" ~ key ~ "' must be a boolean");
        return v.boolean;
    }

    /// The string-array value of `key`, or `fallback` if absent.
    const(string)[] getArray(string key, const(string)[] fallback = null) const
    {
        auto v = find(key);
        if (v is null)
            return fallback;
        if (v.kind != TomlKind.array)
            throw new TomlException("key '" ~ key ~ "' must be an array");
        return v.array;
    }
}

/// Thrown for input that is not in the supported subset.
class TomlException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

private bool isBlank(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t';
}

private bool isKeyChar(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '-';
}

private int hexDigit(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private void appendUtf8(ref char[] buf, uint cp) pure nothrow @safe
{
    if (cp < 0x80)
        buf ~= cast(char) cp;
    else if (cp < 0x800)
    {
        buf ~= cast(char)(0xC0 | (cp >> 6));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        buf ~= cast(char)(0xE0 | (cp >> 12));
        buf ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        buf ~= cast(char)(0xF0 | (cp >> 18));
        buf ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        buf ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
}

/// Parse a basic string whose opening quote is at `line[i]`; advances `i`
/// past the closing quote.
private string parseString(string line, ref size_t i)
{
    ++i; // opening quote
    size_t runStart = i;
    char[] buf;
    bool escaped = false;
    while (true)
    {
        if (i >= line.length)
            throw new TomlException("unterminated string");
        immutable c = line[i];
        if (c == '"')
            break;
        if (c != '\\')
        {
            ++i;
            continue;
        }
        if (!escaped)
        {
            escaped = true;
            buf.length = 0;
        }
        buf ~= line[runStart .. i];
        ++i;
        if (i >= line.length)
            throw new TomlException("bad escape");
        switch (line[i])
        {
        case '"': buf ~= '"'; ++i; break;
        case '\\': buf ~= '\\'; ++i; break;
        case 'n': buf ~= '\n'; ++i; break;
        case 't': buf ~= '\t'; ++i; break;
        case 'r': buf ~= '\r'; ++i; break;
        case 'u':
            if (i + 4 >= line.length)
                throw new TomlException("bad \\u escape");
            uint cp = 0;
            foreach (k; 1 .. 5)
            {
                immutable d = hexDigit(line[i + k]);
                if (d < 0)
                    throw new TomlException("bad \\u escape");
                cp = cp * 16 + d;
            }
            appendUtf8(buf, cp);
            i += 5;
            break;
        default:
            throw new TomlException("unknown escape");
        }
        runStart = i;
    }
    string result;
    if (escaped)
    {
        buf ~= line[runStart .. i];
        result = buf.idup;
    }
    else
        result = line[runStart .. i];
    ++i; // closing quote
    return result;
}

private TomlValue parseValue(string line, ref size_t i)
{
    TomlValue v;
    if (i >= line.length)
        throw new TomlException("missing value");
    immutable c = line[i];
    if (c == '"')
    {
        v.kind = TomlKind.string_;
        v.str = parseString(line, i);
    }
    else if (c == '[')
    {
        v.kind = TomlKind.array;
        ++i;
        while (true)
        {
            while (i < line.length && isBlank(line[i]))
                ++i;
            if (i >= line.length)
                throw new TomlException("unterminated array");
            if (line[i] == ']')
            {
                ++i;
                break;
            }
            if (line[i] != '"')
                throw new TomlException("array elements must be strings");
            v.array ~= parseString(line, i);
            while (i < line.length && isBlank(line[i]))
                ++i;
            if (i < line.length && line[i] == ',')
                ++i;
            else if (i < line.length && line[i] == ']')
            {
                ++i;
                break;
            }
            else
                throw new TomlException("bad array");
        }
    }
    else if (line[i .. $].length >= 4 && line[i .. i + 4] == "true")
    {
        v.kind = TomlKind.boolean;
        v.boolean = true;
        i += 4;
    }
    else if (line[i .. $].length >= 5 && line[i .. i + 5] == "false")
    {
        v.kind = TomlKind.boolean;
        v.boolean = false;
        i += 5;
    }
    else
    {
        size_t start = i;
        if (c == '-')
            ++i;
        size_t digits = i;
        while (i < line.length && line[i] >= '0' && line[i] <= '9')
            ++i;
        if (i == digits)
            throw new TomlException("bad value");
        v.kind = TomlKind.integer;
        v.integer = line[start .. i].to!long;
    }
    return v;
}

/// Parse a TOML-subset document.
TomlDocument parseToml(string text)
{
    TomlDocument doc;
    size_t pos = 0;
    while (pos <= text.length)
    {
        size_t e = pos;
        while (e < text.length && text[e] != '\n')
            ++e;
        string line = text[pos .. e];
        pos = e + 1;

        size_t i = 0;
        while (i < line.length && isBlank(line[i]))
            ++i;
        if (i >= line.length || line[i] == '#')
            continue;
        size_t keyStart = i;
        while (i < line.length && isKeyChar(line[i]))
            ++i;
        if (i == keyStart)
            throw new TomlException("expected a key: " ~ line);
        string key = line[keyStart .. i];
        while (i < line.length && isBlank(line[i]))
            ++i;
        if (i >= line.length || line[i] != '=')
            throw new TomlException("expected '=' after key '" ~ key ~ "'");
        ++i;
        while (i < line.length && isBlank(line[i]))
            ++i;
        auto value = parseValue(line, i);
        while (i < line.length && isBlank(line[i]))
            ++i;
        if (i < line.length && line[i] != '#')
            throw new TomlException("unexpected text after value of '" ~ key ~ "'");
        doc.entries ~= TomlEntry(key, value);
    }
    return doc;
}

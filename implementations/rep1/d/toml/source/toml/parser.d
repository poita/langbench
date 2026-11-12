/**
 * The TOML 1.0.0 parser.
 *
 * A single-pass recursive-descent parser over the UTF-8 text. It builds a
 * `Node` tree and tracks, for every table, how it came into existence so that
 * the redefinition rules of the specification can be enforced.
 */
module toml.parser;

import toml.datetime : parseDateTime;
import toml.exception : TomlException;
import toml.number : parseNumber;
import toml.utf8 : appendUtf8, firstInvalidUtf8;
import toml.value;

/**
 * Parses a TOML document.
 *
 * Params:
 *     source = the complete document; it is validated as UTF-8.
 * Returns: the root table.
 * Throws: `TomlException` if the document is not valid TOML 1.0.0.
 */
Node parse(const(char)[] source) @safe
{
    auto p = Parser(source);
    return p.run();
}

private:

bool isBareKeyChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '-';
}

bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }

bool isTokenChar(char c) @safe pure nothrow @nogc
{
    return isBareKeyChar(c) || c == '+' || c == '.' || c == ':';
}

int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

struct Parser
{
    const(char)[] src;
    size_t pos;
    Node root;
    Node current;

    this(const(char)[] source) @safe
    {
        src = source;
    }

    // ---------------------------------------------------------------- errors

    noreturn fail(string msg, size_t at = size_t.max) const @safe
    {
        throw new TomlException(msg, src, at == size_t.max ? pos : at);
    }

    // --------------------------------------------------------------- helpers

    bool eof() const @safe pure nothrow @nogc { return pos >= src.length; }

    char peek() const @safe pure nothrow @nogc { return src[pos]; }

    bool startsWith(string s) const @safe pure nothrow @nogc
    {
        return src.length - pos >= s.length && src[pos .. pos + s.length] == s;
    }

    void skipWs() @safe pure nothrow @nogc
    {
        while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
            ++pos;
    }

    /// Skips a comment; `pos` is on the `#`. Stops before the line break.
    void skipComment() @safe
    {
        ++pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\n' || c == '\r')
                return;
            if ((c < 0x20 && c != '\t') || c == 0x7F)
                fail("control character in comment");
            ++pos;
        }
    }

    /// Consumes one line break (LF or CRLF). A lone CR cannot occur: it is rejected up front.
    bool skipNewline() @safe pure nothrow @nogc
    {
        if (pos < src.length && src[pos] == '\n')
        {
            ++pos;
            return true;
        }
        if (pos + 1 < src.length && src[pos] == '\r' && src[pos + 1] == '\n')
        {
            pos += 2;
            return true;
        }
        return false;
    }

    /// Skips whitespace, comments and line breaks (inside arrays).
    void skipBlank() @safe
    {
        for (;;)
        {
            skipWs();
            if (eof)
                return;
            if (src[pos] == '#')
                skipComment();
            else if (!skipNewline())
                return;
        }
    }

    // ------------------------------------------------------------- top level

    Node run() @safe
    {
        if (src.length >= 3 && src[0 .. 3] == "\xEF\xBB\xBF")
            fail("byte order mark", 0);
        immutable bad = firstInvalidUtf8(src);
        if (bad != size_t.max)
            fail("invalid UTF-8", bad);
        foreach (i, c; src)
        {
            if (c == '\r' && (i + 1 >= src.length || src[i + 1] != '\n'))
                fail("carriage return not followed by line feed", i);
        }

        root = Node.newTable();
        root.state = TableState.explicit;
        current = root;

        for (;;)
        {
            skipWs();
            if (eof)
                break;
            immutable c = src[pos];
            if (c == '[')
                parseHeader();
            else if (c != '#' && c != '\n' && c != '\r')
                parseKeyValue();
            skipWs();
            if (!eof && src[pos] == '#')
                skipComment();
            if (eof)
                break;
            if (!skipNewline())
                fail("unexpected character after statement");
        }
        return root;
    }

    // ------------------------------------------------------------------ keys

    string parseSimpleKey() @safe
    {
        if (eof)
            fail("expected a key");
        immutable c = src[pos];
        if (c == '"')
        {
            ++pos;
            return parseBasicString();
        }
        if (c == '\'')
        {
            ++pos;
            return parseLiteralString();
        }
        immutable start = pos;
        while (pos < src.length && isBareKeyChar(src[pos]))
            ++pos;
        if (pos == start)
            fail("expected a key");
        return src[start .. pos].idup;
    }

    /// Parses `key` or `a . b . c`, including surrounding whitespace.
    string[] parseKey() @safe
    {
        string[] parts;
        skipWs();
        parts ~= parseSimpleKey();
        for (;;)
        {
            skipWs();
            if (!eof && src[pos] == '.')
            {
                ++pos;
                skipWs();
                parts ~= parseSimpleKey();
            }
            else
                break;
        }
        return parts;
    }

    // --------------------------------------------------------------- strings

    string parseBasicString() @safe
    {
        char[] buf;
        for (;;)
        {
            immutable start = pos;
            while (pos < src.length)
            {
                immutable c = src[pos];
                if (c == '"' || c == '\\' || (c < 0x20 && c != '\t') || c == 0x7F)
                    break;
                ++pos;
            }
            buf ~= src[start .. pos];
            if (eof)
                fail("unterminated string");
            immutable c = src[pos];
            if (c == '"')
            {
                ++pos;
                return buf.idup;
            }
            if (c == '\\')
            {
                ++pos;
                parseEscape(buf);
            }
            else
                fail("invalid character in string");
        }
    }

    /// Parses the escape after a backslash (`pos` is just past the backslash).
    void parseEscape(ref char[] buf) @safe
    {
        if (eof)
            fail("unterminated escape");
        immutable c = src[pos++];
        switch (c)
        {
        case 'b': buf ~= '\b'; break;
        case 't': buf ~= '\t'; break;
        case 'n': buf ~= '\n'; break;
        case 'f': buf ~= '\f'; break;
        case 'r': buf ~= '\r'; break;
        case '"': buf ~= '"'; break;
        case '\\': buf ~= '\\'; break;
        case 'u': appendUtf8(buf, parseHex(4)); break;
        case 'U': appendUtf8(buf, parseHex(8)); break;
        default: fail("invalid escape sequence", pos - 1);
        }
    }

    uint parseHex(size_t count) @safe
    {
        if (src.length - pos < count)
            fail("truncated unicode escape");
        uint v = 0;
        foreach (_; 0 .. count)
        {
            immutable d = hexValue(src[pos]);
            if (d < 0)
                fail("invalid hex digit in unicode escape");
            v = (v << 4) | d;
            ++pos;
        }
        if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF))
            fail("escape is not a unicode scalar value");
        return v;
    }

    string parseLiteralString() @safe
    {
        immutable start = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\'')
            {
                ++pos;
                return src[start .. pos - 1].idup;
            }
            if ((c < 0x20 && c != '\t') || c == 0x7F)
                fail("invalid character in literal string");
            ++pos;
        }
        fail("unterminated literal string");
    }

    /// Counts the run of `q` characters starting at `pos`.
    size_t quoteRun(char q) const @safe pure nothrow @nogc
    {
        size_t n = 0;
        while (pos + n < src.length && src[pos + n] == q)
            ++n;
        return n;
    }

    string parseMultilineBasic() @safe
    {
        // `pos` is just past the opening delimiter.
        skipNewline();
        char[] buf;
        for (;;)
        {
            if (eof)
                fail("unterminated multi-line string");
            immutable c = src[pos];
            if (c == '"')
            {
                immutable n = quoteRun('"');
                if (n < 3)
                {
                    foreach (_; 0 .. n)
                        buf ~= '"';
                    pos += n;
                }
                else if (n <= 5)
                {
                    foreach (_; 0 .. n - 3)
                        buf ~= '"';
                    pos += n;
                    return buf.idup;
                }
                else
                    fail("too many quotes in multi-line string");
            }
            else if (c == '\\')
            {
                ++pos;
                if (!eof && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r'))
                {
                    // Line-ending backslash: whitespace then a newline.
                    size_t p = pos;
                    while (p < src.length && (src[p] == ' ' || src[p] == '\t'))
                        ++p;
                    pos = p;
                    if (!skipNewline())
                        fail("invalid escape sequence", pos);
                    for (;;)
                    {
                        skipWs();
                        if (!skipNewline())
                            break;
                    }
                }
                else
                    parseEscape(buf);
            }
            else if (c == '\n')
            {
                buf ~= '\n';
                ++pos;
            }
            else if (c == '\r')
            {
                // CRLF becomes LF.
                buf ~= '\n';
                pos += 2;
            }
            else if ((c < 0x20 && c != '\t') || c == 0x7F)
                fail("invalid character in multi-line string");
            else
            {
                immutable start = pos;
                while (pos < src.length)
                {
                    immutable d = src[pos];
                    if (d == '"' || d == '\\' || d == '\n' || d == '\r'
                        || (d < 0x20 && d != '\t') || d == 0x7F)
                        break;
                    ++pos;
                }
                buf ~= src[start .. pos];
            }
        }
    }

    string parseMultilineLiteral() @safe
    {
        skipNewline();
        char[] buf;
        for (;;)
        {
            if (eof)
                fail("unterminated multi-line literal string");
            immutable c = src[pos];
            if (c == '\'')
            {
                immutable n = quoteRun('\'');
                if (n < 3)
                {
                    foreach (_; 0 .. n)
                        buf ~= '\'';
                    pos += n;
                }
                else if (n <= 5)
                {
                    foreach (_; 0 .. n - 3)
                        buf ~= '\'';
                    pos += n;
                    return buf.idup;
                }
                else
                    fail("too many quotes in multi-line literal string");
            }
            else if (c == '\n')
            {
                buf ~= '\n';
                ++pos;
            }
            else if (c == '\r')
            {
                buf ~= '\n';
                pos += 2;
            }
            else if ((c < 0x20 && c != '\t') || c == 0x7F)
                fail("invalid character in multi-line literal string");
            else
            {
                immutable start = pos;
                while (pos < src.length)
                {
                    immutable d = src[pos];
                    if (d == '\'' || d == '\n' || d == '\r' || (d < 0x20 && d != '\t') || d == 0x7F)
                        break;
                    ++pos;
                }
                buf ~= src[start .. pos];
            }
        }
    }

    // ---------------------------------------------------------------- values

    Node parseValue() @safe
    {
        if (eof)
            fail("expected a value");
        switch (src[pos])
        {
        case '"':
            if (startsWith(`"""`))
            {
                pos += 3;
                return Node.fromString(parseMultilineBasic());
            }
            ++pos;
            return Node.fromString(parseBasicString());
        case '\'':
            if (startsWith("'''"))
            {
                pos += 3;
                return Node.fromString(parseMultilineLiteral());
            }
            ++pos;
            return Node.fromString(parseLiteralString());
        case '[':
            return parseArray();
        case '{':
            return parseInlineTable();
        default:
            return parseScalar();
        }
    }

    Node parseScalar() @safe
    {
        immutable start = pos;
        while (pos < src.length && isTokenChar(src[pos]))
            ++pos;
        auto tok = src[start .. pos];
        if (tok.length == 0)
            fail("expected a value", start);
        if (tok == "true")
            return Node.fromBool(true);
        if (tok == "false")
            return Node.fromBool(false);

        Kind kind;
        string text;
        bool ok;
        if (tok.length >= 5 && digitsAt(tok, 0, 4) && tok[4] == '-')
        {
            // A date may be followed by a space and a complete time.
            if (tok.length == 10 && pos + 3 < src.length && src[pos] == ' '
                && isDigit(src[pos + 1]) && isDigit(src[pos + 2]) && src[pos + 3] == ':')
            {
                ++pos;
                while (pos < src.length && isTokenChar(src[pos]))
                    ++pos;
                tok = src[start .. pos];
            }
            ok = parseDateTime(tok, kind, text);
        }
        else if (tok.length >= 3 && digitsAt(tok, 0, 2) && tok[2] == ':')
            ok = parseDateTime(tok, kind, text);
        else
            ok = parseNumber(tok, kind, text);
        if (!ok)
            fail("invalid value", start);
        return Node.scalar(kind, text);
    }

    static bool digitsAt(const(char)[] s, size_t from, size_t n) @safe pure nothrow @nogc
    {
        if (from + n > s.length)
            return false;
        foreach (c; s[from .. from + n])
            if (!isDigit(c))
                return false;
        return true;
    }

    Node parseArray() @safe
    {
        ++pos; // '['
        auto arr = Node.newArray();
        for (;;)
        {
            skipBlank();
            if (eof)
                fail("unterminated array");
            if (src[pos] == ']')
            {
                ++pos;
                return arr;
            }
            arr.items ~= parseValue();
            skipBlank();
            if (eof)
                fail("unterminated array");
            if (src[pos] == ',')
                ++pos;
            else if (src[pos] == ']')
            {
                ++pos;
                return arr;
            }
            else
                fail("expected ',' or ']' in array");
        }
    }

    Node parseInlineTable() @safe
    {
        ++pos; // '{'
        auto table = Node.newTable();
        table.state = TableState.inlineTable;
        skipWs();
        if (!eof && src[pos] == '}')
        {
            ++pos;
            return table;
        }
        for (;;)
        {
            auto key = parseKey();
            skipWs();
            if (eof || src[pos] != '=')
                fail("expected '=' after key");
            ++pos;
            skipWs();
            auto value = parseValue();
            assignDotted(table, key, value);
            skipWs();
            if (eof)
                fail("unterminated inline table");
            if (src[pos] == ',')
            {
                ++pos;
                skipWs();
            }
            else if (src[pos] == '}')
            {
                ++pos;
                return table;
            }
            else
                fail("expected ',' or '}' in inline table");
        }
    }

    // ------------------------------------------------------- key/value pairs

    void parseKeyValue() @safe
    {
        immutable keyPos = pos;
        auto key = parseKey();
        skipWs();
        if (eof || src[pos] != '=')
            fail("expected '=' after key");
        ++pos;
        skipWs();
        auto value = parseValue();
        assignDotted(current, key, value, keyPos);
    }

    /// Stores `value` under the dotted `key` relative to `table` (rule 4).
    void assignDotted(Node table, const(string)[] key, Node value, size_t at = size_t.max) @safe
    {
        auto t = table;
        foreach (part; key[0 .. $ - 1])
        {
            if (auto p = part in t.members)
            {
                auto child = *p;
                if (child.kind != Kind.table
                    || child.state == TableState.explicit || child.state == TableState.inlineTable)
                    fail("key redefines an existing value or table", at);
                t = child;
            }
            else
            {
                auto child = Node.newTable();
                child.state = TableState.dotted;
                t.members[part] = child;
                t = child;
            }
        }
        immutable last = key[$ - 1];
        if (last in t.members)
            fail("duplicate key", at);
        t.members[last] = value;
    }

    // --------------------------------------------------------------- headers

    void parseHeader() @safe
    {
        immutable at = pos;
        ++pos; // '['
        immutable isArray = !eof && src[pos] == '[';
        if (isArray)
            ++pos;
        auto key = parseKey();
        if (eof || src[pos] != ']')
            fail("expected ']'");
        ++pos;
        if (isArray)
        {
            if (eof || src[pos] != ']')
                fail("expected ']]'");
            ++pos;
        }

        // Resolve the intermediate segments (rule 2).
        auto t = root;
        foreach (part; key[0 .. $ - 1])
        {
            if (auto p = part in t.members)
            {
                auto child = *p;
                if (child.kind == Kind.table && child.state != TableState.inlineTable)
                    t = child;
                else if (child.kind == Kind.array && child.fromHeader)
                    t = child.items[$ - 1];
                else
                    fail("header path crosses a non-table value", at);
            }
            else
            {
                auto child = Node.newTable();
                child.state = TableState.implicit;
                t.members[part] = child;
                t = child;
            }
        }

        immutable last = key[$ - 1];
        if (isArray)
        {
            auto element = Node.newTable();
            element.state = TableState.explicit;
            if (auto p = last in t.members)
            {
                if ((*p).kind != Kind.array || !(*p).fromHeader)
                    fail("array of tables conflicts with an existing key", at);
                (*p).items ~= element;
            }
            else
            {
                auto arr = Node.newArray();
                arr.fromHeader = true;
                arr.items ~= element;
                t.members[last] = arr;
            }
            current = element;
        }
        else
        {
            if (auto p = last in t.members)
            {
                if ((*p).kind != Kind.table || (*p).state != TableState.implicit)
                    fail("table is already defined", at);
                (*p).state = TableState.explicit;
                current = *p;
            }
            else
            {
                auto table = Node.newTable();
                table.state = TableState.explicit;
                t.members[last] = table;
                current = table;
            }
        }
    }
}

// ------------------------------------------------------------------- tests

version (unittest)
{
    import toml.json : toTaggedJson;

    private string decode(string doc) { return toTaggedJson(parse(doc)); }

    private bool invalid(string doc)
    {
        try
        {
            parse(doc);
            return false;
        }
        catch (TomlException)
            return true;
    }
}

unittest // scalars and strings
{
    assert(decode("") == "{}");
    assert(decode("a = 1\r\nb = 'x'\n") ==
        `{"a":{"type":"integer","value":"1"},"b":{"type":"string","value":"x"}}`);
    assert(decode(`s = "a\tb\u00e9\U0001F600"`) ==
        `{"s":{"type":"string","value":"a\tbé😀"}}`);
    assert(decode("s = \"\"\"\nline1\\\n   line2\r\nx\"\"\"\"") ==
        `{"s":{"type":"string","value":"line1line2\nx\""}}`);
    assert(decode("s = '''\nraw \\n ''''") == `{"s":{"type":"string","value":"raw \\n '"}}`);
    assert(decode("d = 1979-05-27 # c") == `{"d":{"type":"date-local","value":"1979-05-27"}}`);
    assert(decode("d = 1979-05-27 07:32:00Z") ==
        `{"d":{"type":"datetime","value":"1979-05-27T07:32:00Z"}}`);
    assert(decode("f = -nan") == `{"f":{"type":"float","value":"nan"}}`);
}

unittest // tables
{
    assert(decode("[a.b]\nx=1\n[a]\ny=2") ==
        `{"a":{"b":{"x":{"type":"integer","value":"1"}},"y":{"type":"integer","value":"2"}}}`);
    assert(decode("a.b = 1\na.c = 2\n[x.y]\n") ==
        `{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}},"x":{"y":{}}}`);
    assert(decode("[[f]]\nn=1\n[f.p]\nc=2\n[[f.v]]\nm=3\n[[f]]\nn=4") ==
        `{"f":[{"n":{"type":"integer","value":"1"},"p":{"c":{"type":"integer","value":"2"}},`
        ~ `"v":[{"m":{"type":"integer","value":"3"}}]},{"n":{"type":"integer","value":"4"}}]}`);
    assert(decode("t = { a.b = 1, a.c = [\n 2,\n], d = {} }") ==
        `{"t":{"a":{"b":{"type":"integer","value":"1"},"c":[{"type":"integer","value":"2"}]},"d":{}}}`);
    assert(!invalid("[fruit]\napple.color = 'red'\n[fruit.apple.texture]\nx=1"));
    assert(invalid("[fruit]\napple.color = 'red'\n[fruit.apple]"));
}

unittest // invalid documents
{
    foreach (doc; [
        "a = ", "a = 1 b = 2", "a = 1\na = 2", "[a]\n[a]", "a.b = 1\n[a]", "[a]\nb.c = 1\n[a.b]",
        "a = {b = 1}\n[a.c]", "a = {b = 1}\na.c = 2", "a = {b = 1,}", "a = {\nb = 1}",
        "a = [1,,2]", "a = [,1]", "a = [[1]", "[ [a] ]", "[[a] ]", "a = [1]\n[[a]]",
        "a = 1\n[a.b]", "[a]\nb = 1\n[a.b.c]", "\xEF\xBB\xBFa = 1", "a = 1\rb = 2", "a = \"\xFF\"",
        "a = \"\\x\"", "a = \"\\ud800\"", "a = \"\\U00110000\"", "a = 'x\ny'", "a = \"x\ny\"",
        "a = \"\"\"x\"\"\"\"\"\"", "# bad \x01", "a = 01", "a = 1__0", "a = 0xFFFFFFFFFFFFFFFF",
        "a = 1979-02-30", "a = 17:45", "a = 1979-05-27 07:32", "a = tru", "a = True", "=1",
        "a = 1 # x\x7f", "\"\"\"a\"\"\" = 1", "[a]]", "a = [1 2]", "a = \"x",
    ])
        assert(invalid(doc), doc);
}

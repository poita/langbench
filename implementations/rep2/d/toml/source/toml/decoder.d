/**
 * The TOML 1.0.0 decoder: a single-pass recursive-descent parser that builds a
 * `Node` tree.
 *
 * The parser works directly on UTF-8 bytes. The whole input is validated as
 * UTF-8 up front; after that every syntactic character is ASCII, and bytes
 * >= 0x80 only ever appear (legally) inside strings, quoted keys and comments.
 */
module toml.decoder;

import std.array : Appender, appender;

import toml.datetime : parseDateTime;
import toml.node;
import toml.numbers : parseFloat, parseInteger;
import toml.utf8 : encodeUtf8, findInvalidUtf8, isScalarValue;

/**
 * Parses a TOML 1.0.0 document.
 *
 * Params:
 *     data = the document, as raw bytes (must be valid UTF-8)
 * Returns: the root table
 * Throws: `TomlException` if the document is not valid TOML
 */
Node parseToml(const(ubyte)[] data)
{
    if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
        throw new TomlException("byte-order mark is not allowed", 0);
    immutable bad = findInvalidUtf8(data);
    if (bad != size_t.max)
        throw new TomlException("invalid UTF-8", bad);
    auto p = Parser(cast(string) data.idup);
    return p.parseDocument();
}

/// ditto
Node parseToml(string text)
{
    return parseToml(cast(const(ubyte)[]) text);
}

private:

bool isBareKeyChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '-';
}

/// Characters that can make up a bare (unquoted) value token.
bool isTokenChar(char c) @safe pure nothrow @nogc
{
    return isBareKeyChar(c) || c == '+' || c == '.' || c == ':';
}

bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

bool isHexDigit(char c) @safe pure nothrow @nogc
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

uint hexValue(char c) @safe pure nothrow @nogc
{
    if (isDigit(c)) return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

/// Characters never allowed raw in strings and comments (tab is allowed).
bool isForbiddenControl(char c) @safe pure nothrow @nogc
{
    return (c < 0x20 && c != '\t') || c == 0x7F;
}

struct Parser
{
    string src;
    size_t pos;
    Node root;
    Node current;

    this(string s)
    {
        src = s;
        root = table();
        root.explicit = true;
        current = root;
    }

    // ---- primitives ------------------------------------------------------

    bool eof() const @safe pure nothrow @nogc { return pos >= src.length; }

    char peek() const @safe pure nothrow @nogc { return src[pos]; }

    char peekAt(size_t n) const @safe pure nothrow @nogc
    {
        return pos + n < src.length ? src[pos + n] : '\0';
    }

    bool has(size_t n) const @safe pure nothrow @nogc { return pos + n <= src.length; }

    noreturn fail(string msg)
    {
        throw new TomlException(msg, pos);
    }

    void expect(char c)
    {
        if (eof || src[pos] != c)
            fail("expected '" ~ c ~ "'");
        pos++;
    }

    void skipWs() @safe pure nothrow @nogc
    {
        while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
            pos++;
    }

    /// Length of the newline at `pos` (LF or CRLF), or 0 if none.
    size_t newlineLen() const @safe pure nothrow @nogc
    {
        if (pos < src.length)
        {
            if (src[pos] == '\n')
                return 1;
            if (src[pos] == '\r' && pos + 1 < src.length && src[pos + 1] == '\n')
                return 2;
        }
        return 0;
    }

    bool eatNewline() @safe pure nothrow @nogc
    {
        immutable n = newlineLen();
        pos += n;
        return n != 0;
    }

    /// Skips a comment; `pos` is at the '#'. Stops before the newline.
    void skipComment()
    {
        pos++;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\n' || (c == '\r' && peekAt(1) == '\n'))
                return;
            if (isForbiddenControl(c) || c == '\r')
                fail("control character in comment");
            pos++;
        }
    }

    /// Skips whitespace, newlines and comments (used inside arrays).
    void skipWsNlComments()
    {
        while (true)
        {
            skipWs();
            if (eof)
                return;
            if (src[pos] == '#')
                skipComment();
            else if (!eatNewline())
                return;
        }
    }

    // ---- document structure ---------------------------------------------

    Node parseDocument()
    {
        while (true)
        {
            skipWs();
            if (eof)
                break;
            immutable c = src[pos];
            if (c == '#')
                skipComment();
            else if (c == '\n' || c == '\r')
            {
            }
            else if (c == '[')
                parseHeader();
            else
                parseKeyValue();
            skipWs();
            if (eof)
                break;
            if (src[pos] == '#')
                skipComment();
            if (eof)
                break;
            if (!eatNewline())
                fail("unexpected characters at end of line");
        }
        return root;
    }

    void parseHeader()
    {
        bool isArray = peekAt(1) == '[';
        pos += isArray ? 2 : 1;
        auto keys = parseKey();
        skipWs();
        expect(']');
        if (isArray)
            expect(']');
        current = isArray ? openArrayTable(keys) : openTable(keys);
    }

    void parseKeyValue()
    {
        auto keys = parseKey();
        skipWs();
        expect('=');
        skipWs();
        auto v = parseValue();
        assign(current, keys, v);
    }

    // ---- table resolution ------------------------------------------------

    /// Walks the intermediate segments of a header, creating implicit tables.
    Node walkHeader(string[] keys)
    {
        auto t = root;
        foreach (k; keys[0 .. $ - 1])
        {
            auto p = k in t.entries;
            if (p is null)
            {
                auto n = table();
                t.entries[k] = n;
                t = n;
                continue;
            }
            auto n = *p;
            if (n.isTable && !n.inline)
                t = n;
            else if (n.isArray && n.arrayOfTables)
                t = n.items[$ - 1];
            else
                fail("cannot extend '" ~ k ~ "'");
        }
        return t;
    }

    Node openTable(string[] keys)
    {
        auto parent = walkHeader(keys);
        immutable last = keys[$ - 1];
        auto p = last in parent.entries;
        if (p is null)
        {
            auto n = table();
            n.explicit = true;
            parent.entries[last] = n;
            return n;
        }
        auto n = *p;
        if (!n.isTable || n.explicit || n.dotted || n.inline)
            fail("table '" ~ last ~ "' is already defined");
        n.explicit = true;
        return n;
    }

    Node openArrayTable(string[] keys)
    {
        auto parent = walkHeader(keys);
        immutable last = keys[$ - 1];
        auto elem = table();
        elem.explicit = true;
        auto p = last in parent.entries;
        if (p is null)
        {
            auto arr = array();
            arr.arrayOfTables = true;
            arr.items ~= elem;
            parent.entries[last] = arr;
            return elem;
        }
        auto n = *p;
        if (!n.isArray || !n.arrayOfTables)
            fail("'" ~ last ~ "' is not an array of tables");
        n.items ~= elem;
        return elem;
    }

    /// Stores `value` at the (possibly dotted) `keys` relative to `base`.
    void assign(Node base, string[] keys, Node value)
    {
        auto t = base;
        foreach (k; keys[0 .. $ - 1])
        {
            auto p = k in t.entries;
            if (p is null)
            {
                auto n = table();
                n.dotted = true;
                t.entries[k] = n;
                t = n;
                continue;
            }
            auto n = *p;
            if (!n.isTable || n.explicit || n.inline)
                fail("cannot extend '" ~ k ~ "' with a dotted key");
            t = n;
        }
        immutable last = keys[$ - 1];
        if (last in t.entries)
            fail("duplicate key '" ~ last ~ "'");
        t.entries[last] = value;
    }

    // ---- keys ------------------------------------------------------------

    string[] parseKey()
    {
        string[] keys;
        while (true)
        {
            skipWs();
            keys ~= parseSimpleKey();
            skipWs();
            if (!eof && src[pos] == '.')
                pos++;
            else
                return keys;
        }
    }

    string parseSimpleKey()
    {
        if (eof)
            fail("expected a key");
        immutable c = src[pos];
        if (c == '"')
            return parseBasicString();
        if (c == '\'')
            return parseLiteralString();
        immutable start = pos;
        while (pos < src.length && isBareKeyChar(src[pos]))
            pos++;
        if (pos == start)
            fail("expected a key");
        return src[start .. pos];
    }

    // ---- strings ---------------------------------------------------------

    /// Parses an escape sequence; `pos` is just after the backslash.
    void parseEscape(ref Appender!string sink)
    {
        if (eof)
            fail("unterminated escape");
        immutable c = src[pos++];
        switch (c)
        {
        case 'b': sink.put('\b'); break;
        case 't': sink.put('\t'); break;
        case 'n': sink.put('\n'); break;
        case 'f': sink.put('\f'); break;
        case 'r': sink.put('\r'); break;
        case '"': sink.put('"'); break;
        case '\\': sink.put('\\'); break;
        case 'u':
        case 'U':
            immutable n = c == 'u' ? 4 : 8;
            if (!has(n))
                fail("truncated unicode escape");
            uint cp = 0;
            foreach (k; 0 .. n)
            {
                immutable h = src[pos + k];
                if (!isHexDigit(h))
                    fail("bad unicode escape");
                cp = cp * 16 + hexValue(h);
            }
            if (!isScalarValue(cp))
                fail("escape is not a unicode scalar value");
            pos += n;
            encodeUtf8(sink, cp);
            break;
        default:
            fail("invalid escape sequence");
        }
    }

    /// Basic string; `pos` is at the opening quote.
    string parseBasicString()
    {
        pos++;
        immutable start = pos;
        // Fast path: no escapes, so the value is a slice of the source.
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                pos++;
                return src[start .. pos - 1];
            }
            if (c == '\\')
                break;
            if (isForbiddenControl(c))
                fail("control character in string");
            pos++;
        }
        auto sink = appender!string();
        sink.put(src[start .. pos]);
        while (true)
        {
            if (eof)
                fail("unterminated string");
            immutable c = src[pos++];
            if (c == '"')
                return sink.data;
            if (c == '\\')
                parseEscape(sink);
            else if (isForbiddenControl(c))
            {
                pos--;
                fail("control character in string");
            }
            else
                sink.put(c);
        }
    }

    /// Literal string; `pos` is at the opening quote.
    string parseLiteralString()
    {
        pos++;
        immutable start = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\'')
            {
                pos++;
                return src[start .. pos - 1];
            }
            if (isForbiddenControl(c))
                fail("control character in string");
            pos++;
        }
        fail("unterminated string");
    }

    /// Counts the run of `q` characters at `pos` without consuming it.
    size_t quoteRun(char q) const @safe pure nothrow @nogc
    {
        size_t n = 0;
        while (pos + n < src.length && src[pos + n] == q)
            n++;
        return n;
    }

    /// Multi-line basic string; `pos` is at the opening `"""`.
    string parseMultilineBasicString()
    {
        pos += 3;
        eatNewline();
        auto sink = appender!string();
        while (true)
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
                        sink.put('"');
                    pos += n;
                    continue;
                }
                if (n > 5)
                    fail("too many quotes");
                foreach (_; 0 .. n - 3)
                    sink.put('"');
                pos += n;
                return sink.data;
            }
            if (c == '\\')
            {
                pos++;
                // Line-ending backslash: optional whitespace, then a newline.
                size_t j = pos;
                while (j < src.length && (src[j] == ' ' || src[j] == '\t'))
                    j++;
                immutable save = pos;
                pos = j;
                if (newlineLen() != 0)
                {
                    while (true)
                    {
                        skipWs();
                        if (!eatNewline())
                            break;
                    }
                }
                else
                {
                    pos = save;
                    parseEscape(sink);
                }
                continue;
            }
            if (c == '\r' || c == '\n')
            {
                if (!eatNewline())
                    fail("bare carriage return");
                sink.put('\n');
                continue;
            }
            if (isForbiddenControl(c))
                fail("control character in string");
            sink.put(c);
            pos++;
        }
    }

    /// Multi-line literal string; `pos` is at the opening `'''`.
    string parseMultilineLiteralString()
    {
        pos += 3;
        eatNewline();
        auto sink = appender!string();
        while (true)
        {
            if (eof)
                fail("unterminated multi-line string");
            immutable c = src[pos];
            if (c == '\'')
            {
                immutable n = quoteRun('\'');
                if (n < 3)
                {
                    foreach (_; 0 .. n)
                        sink.put('\'');
                    pos += n;
                    continue;
                }
                if (n > 5)
                    fail("too many quotes");
                foreach (_; 0 .. n - 3)
                    sink.put('\'');
                pos += n;
                return sink.data;
            }
            if (c == '\r' || c == '\n')
            {
                if (!eatNewline())
                    fail("bare carriage return");
                sink.put('\n');
                continue;
            }
            if (isForbiddenControl(c))
                fail("control character in string");
            sink.put(c);
            pos++;
        }
    }

    // ---- values ----------------------------------------------------------

    Node parseValue()
    {
        if (eof)
            fail("expected a value");
        switch (src[pos])
        {
        case '"':
            if (peekAt(1) == '"' && peekAt(2) == '"')
                return scalar(ScalarType.string_, parseMultilineBasicString());
            return scalar(ScalarType.string_, parseBasicString());
        case '\'':
            if (peekAt(1) == '\'' && peekAt(2) == '\'')
                return scalar(ScalarType.string_, parseMultilineLiteralString());
            return scalar(ScalarType.string_, parseLiteralString());
        case '[':
            return parseArray();
        case '{':
            return parseInlineTable();
        default:
            return parseBareValue();
        }
    }

    Node parseArray()
    {
        pos++;
        auto arr = array();
        while (true)
        {
            skipWsNlComments();
            if (!eof && src[pos] == ']')
            {
                pos++;
                return arr;
            }
            arr.items ~= parseValue();
            skipWsNlComments();
            if (eof)
                fail("unterminated array");
            if (src[pos] == ',')
                pos++;
            else if (src[pos] == ']')
            {
                pos++;
                return arr;
            }
            else
                fail("expected ',' or ']'");
        }
    }

    Node parseInlineTable()
    {
        pos++;
        auto t = table();
        t.explicit = true;
        t.inline = true;
        skipWs();
        if (!eof && src[pos] == '}')
        {
            pos++;
            return t;
        }
        while (true)
        {
            auto keys = parseKey();
            skipWs();
            expect('=');
            skipWs();
            auto v = parseValue();
            assign(t, keys, v);
            skipWs();
            if (eof)
                fail("unterminated inline table");
            if (src[pos] == ',')
            {
                pos++;
                skipWs();
            }
            else if (src[pos] == '}')
            {
                pos++;
                return t;
            }
            else
                fail("expected ',' or '}'");
        }
    }

    /// Booleans, numbers and date-times: anything made of token characters.
    Node parseBareValue()
    {
        immutable start = pos;
        while (pos < src.length && isTokenChar(src[pos]))
            pos++;
        auto tok = src[start .. pos];
        if (tok.length == 0)
            fail("expected a value");
        if (tok == "true" || tok == "false")
            return scalar(ScalarType.boolean, tok);

        immutable looksDate = tok.length >= 5 && isDigit(tok[0]) && isDigit(tok[1])
            && isDigit(tok[2]) && isDigit(tok[3]) && tok[4] == '-';
        immutable looksTime = tok.length >= 3 && isDigit(tok[0]) && tok[2] == ':';
        if (looksDate || looksTime)
        {
            // "YYYY-MM-DD HH:MM:SS..." : a space joins date and time only if
            // a time follows.
            if (looksDate && tok.length == 10 && peekAt(0) == ' ' && isDigit(peekAt(1))
                && isDigit(peekAt(2)) && peekAt(3) == ':')
            {
                immutable tstart = pos + 1;
                pos = tstart;
                while (pos < src.length && isTokenChar(src[pos]))
                    pos++;
                tok = tok ~ " " ~ src[tstart .. pos];
            }
            ScalarType ty;
            string canon;
            if (!parseDateTime(tok, ty, canon))
                fail("invalid date or time");
            return scalar(ty, canon);
        }

        string canon;
        if (parseInteger(tok, canon))
            return scalar(ScalarType.integer, canon);
        if (parseFloat(tok, canon))
            return scalar(ScalarType.float_, canon);
        fail("invalid value");
    }
}

version (unittest)
{
    bool invalid(string doc)
    {
        try
        {
            parseToml(doc);
            return false;
        }
        catch (TomlException)
            return true;
    }

    import toml.json : toTaggedJson;

    string dec(string doc)
    {
        return toTaggedJson(parseToml(doc));
    }
}

unittest
{
    assert(dec("") == "{}");
    assert(dec("a = 1") == `{"a":{"type":"integer","value":"1"}}`);
    assert(dec("a.b = 1\na.c = 2") ==
        `{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}}}`);
    assert(dec("[a]\n[a.b]\nx = true") ==
        `{"a":{"b":{"x":{"type":"bool","value":"true"}}}}`);
    assert(dec("[[a]]\nx = 1\n[a.t]\ny = 2\n[[a]]\n") ==
        `{"a":[{"t":{"y":{"type":"integer","value":"2"}},"x":{"type":"integer","value":"1"}},{}]}`);
    assert(dec("d = 1979-05-27 # c") == `{"d":{"type":"date-local","value":"1979-05-27"}}`);
    assert(dec("d = 1979-05-27 07:32:00") ==
        `{"d":{"type":"datetime-local","value":"1979-05-27T07:32:00"}}`);
    assert(dec("a = {b = [\n1,\n], c.d = 'x'}") ==
        `{"a":{"b":[{"type":"integer","value":"1"}],"c":{"d":{"type":"string","value":"x"}}}}`);
}

unittest // strings
{
    assert(dec(`a = "x\tyé\U0001F600"`) == "{\"a\":{\"type\":\"string\",\"value\":\"x\\tyé\U0001F600\"}}");
    assert(dec("a = \"\"\"\nx\\\n   y\"\"\"\"") == `{"a":{"type":"string","value":"xy\""}}`);
    assert(dec("a = '''\r\nx\r\ny'''") == `{"a":{"type":"string","value":"x\ny"}}`);
    assert(invalid("a = \"\"\"a\"\"\"\"\"\""));       // six quotes
    assert(invalid(`a = "\x"`));
    assert(invalid(`a = "\ud800"`));
    assert(invalid("a = \"x\ny\""));
    assert(invalid("a = 'x\ty\x01'"));
    assert(invalid("a = \"\x7f\""));
    assert(invalid("a = \"a\rb\""));
    assert(invalid("# c\rd\n"));
}

unittest // tables and keys
{
    assert(invalid("a = 1\na = 2"));
    assert(invalid("[a]\n[a]"));
    assert(invalid("a.b = 1\n[a]"));
    assert(invalid("[fruit]\napple.color = 1\n[fruit.apple]"));
    assert(!invalid("[fruit]\napple.color = 1\n[fruit.apple.texture]"));
    assert(invalid("a = {b = 1}\n[a.c]"));
    assert(invalid("a = {b = 1}\na.c = 2"));
    assert(invalid("a = [1]\n[[a]]"));
    assert(invalid("[[a]]\n[a]"));
    assert(invalid("[ [a] ]"));
    assert(!invalid("[[ a . b ]]"));
    assert(invalid("a = {b = 1,}"));
    assert(invalid("a = {b = 1,\nc = 2}"));
    assert(invalid("a = [1,,2]"));
    assert(invalid("a = [,1]"));
    assert(!invalid("a = [1,2,]"));
    assert(invalid("a = 1 b = 2"));
    assert(invalid("a ="));
    assert(invalid("\xef\xbb\xbfa = 1"));
    assert(invalid("a = \"\xff\""));
    assert(!invalid("\"\" = 1\n'a b' = 2\n1234 = 3"));
}

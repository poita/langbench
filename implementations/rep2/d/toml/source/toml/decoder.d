/**
 * TOML 1.0.0 decoder: a single-pass recursive-descent parser that builds a
 * `toml.node.Node` tree.
 *
 * The parser works on bytes. Validity of the UTF-8 stream, the absence of a
 * byte-order mark and of lone CRs is checked up front; after that every
 * grammar rule is ASCII driven and bytes >= 0x80 are copied through.
 */
module toml.decoder;

import toml.errors : TomlException;
import toml.floatfmt : formatFloat, parseFloatDecimal;
import toml.node;
import toml.utf8 : appendUtf8, firstInvalidUtf8, isScalarValue;

/**
 * Parses a TOML 1.0.0 document.
 *
 * Params:
 *     document = the document text; slices of it are shared with the result
 * Returns: the root table
 * Throws: `TomlException` if the document is not valid TOML 1.0.0
 */
Node parseToml(string document)
{
    auto parser = Parser(document);
    return parser.parseDocument();
}

/// ditto (copies the bytes)
Node parseToml(const(ubyte)[] document)
{
    return parseToml((cast(const(char)[]) document).idup);
}

private:

enum ubyte[256] charClass = () {
    // 1: bare key character, 2: ASCII digit (also set for bare), 4: hex digit
    ubyte[256] t;
    foreach (c; 'a' .. 'z' + 1)
        t[c] |= 1;
    foreach (c; 'A' .. 'Z' + 1)
        t[c] |= 1;
    foreach (c; '0' .. '9' + 1)
        t[c] |= 1 | 2 | 4;
    t['_'] |= 1;
    t['-'] |= 1;
    foreach (c; 'a' .. 'f' + 1)
        t[c] |= 4;
    foreach (c; 'A' .. 'F' + 1)
        t[c] |= 4;
    return t;
}();

bool isBare(char c) pure nothrow @nogc => (charClass[c] & 1) != 0;
bool isDigit(char c) pure nothrow @nogc => c >= '0' && c <= '9';
bool isHex(char c) pure nothrow @nogc => (charClass[c] & 4) != 0;

int hexVal(char c) pure nothrow @nogc
{
    if (c <= '9')
        return c - '0';
    return (c | 0x20) - 'a' + 10;
}

struct Parser
{
    string s;
    size_t p;
    Node root;
    Node cur;
    char[] scratch;

    this(string doc)
    {
        s = doc;
    }

    // ------------------------------------------------------------------
    // errors and low-level helpers

    noreturn fail(string msg = "invalid TOML", size_t at = size_t.max)
    {
        throw new TomlException(msg, at == size_t.max ? p : at);
    }

    bool eof() const pure nothrow @nogc => p >= s.length;

    void skipWs()
    {
        while (p < s.length && (s[p] == ' ' || s[p] == '\t'))
            p++;
    }

    /// Consumes LF or CRLF at the cursor if present.
    bool acceptNewline()
    {
        if (p < s.length)
        {
            if (s[p] == '\n')
            {
                p++;
                return true;
            }
            if (s[p] == '\r' && p + 1 < s.length && s[p + 1] == '\n')
            {
                p += 2;
                return true;
            }
        }
        return false;
    }

    /// Skips a comment; the cursor is on `#`. Stops before the newline.
    void skipComment()
    {
        p++;
        while (p < s.length)
        {
            immutable c = s[p];
            if (c == '\n' || c == '\r')
                return;
            if ((c < 0x20 && c != '\t') || c == 0x7F)
                fail("control character in comment");
            p++;
        }
    }

    /// After a statement: optional whitespace, optional comment, then newline or EOF.
    void expectLineEnd()
    {
        skipWs();
        if (p < s.length && s[p] == '#')
            skipComment();
        if (p >= s.length || acceptNewline())
            return;
        fail("unexpected content at end of line");
    }

    /// Whitespace, newlines and comments (inside arrays).
    void skipWsNlComments()
    {
        for (;;)
        {
            skipWs();
            if (p >= s.length)
                return;
            if (s[p] == '#')
                skipComment();
            else if (!acceptNewline())
                return;
        }
    }

    // ------------------------------------------------------------------
    // document

    Node parseDocument()
    {
        if (s.length >= 3 && s[0 .. 3] == "\xEF\xBB\xBF")
            fail("byte-order mark", 0);
        immutable bad = firstInvalidUtf8(s);
        if (bad != s.length)
            fail("invalid UTF-8", bad);
        validateCr();

        root = Node.newTable(Origin.explicit);
        cur = root;
        while (true)
        {
            skipWs();
            if (p >= s.length)
                break;
            immutable c = s[p];
            if (c == '\n' || c == '\r')
            {
                acceptNewline() || fail();
                continue;
            }
            if (c == '#')
            {
                skipComment();
                continue;
            }
            if (c == '[')
                parseHeader();
            else
                parseKeyValue(cur);
            expectLineEnd();
        }
        return root;
    }

    /// Every CR must be followed by LF.
    void validateCr()
    {
        import core.stdc.string : memchr;

        size_t i = 0;
        while (i < s.length)
        {
            auto q = cast(const(char)*) memchr(s.ptr + i, '\r', s.length - i);
            if (q is null)
                return;
            immutable at = q - s.ptr;
            if (at + 1 >= s.length || s[at + 1] != '\n')
                fail("lone CR", at);
            i = at + 2;
        }
    }

    // ------------------------------------------------------------------
    // keys

    string[] parseKey()
    {
        string[] segs;
        for (;;)
        {
            skipWs();
            segs ~= parseSimpleKey();
            skipWs();
            if (p < s.length && s[p] == '.')
            {
                p++;
                continue;
            }
            return segs;
        }
    }

    string parseSimpleKey()
    {
        if (p >= s.length)
            fail("expected key");
        immutable c = s[p];
        if (c == '"')
            return parseBasicString();
        if (c == '\'')
            return parseLiteralString();
        immutable start = p;
        while (p < s.length && isBare(s[p]))
            p++;
        if (p == start)
            fail("expected key");
        return s[start .. p];
    }

    // ------------------------------------------------------------------
    // table headers and key/value pairs

    void parseHeader()
    {
        p++; // '['
        bool isArray = false;
        if (p < s.length && s[p] == '[')
        {
            isArray = true;
            p++;
        }
        auto segs = parseKey();
        skipWs();
        if (p >= s.length || s[p] != ']')
            fail("expected ]");
        p++;
        if (isArray)
        {
            if (p >= s.length || s[p] != ']')
                fail("expected ]]");
            p++;
        }

        Node t = root;
        foreach (seg; segs[0 .. $ - 1])
            t = stepHeader(t, seg);
        immutable last = segs[$ - 1];
        auto existing = last in t.members;
        if (!isArray)
        {
            if (existing is null)
            {
                auto n = Node.newTable(Origin.explicit);
                t.members[last] = n;
                cur = n;
            }
            else if ((*existing).kind == Kind.table && (*existing).origin == Origin.implicit)
            {
                (*existing).origin = Origin.explicit;
                cur = *existing;
            }
            else
                fail("table redefined");
        }
        else
        {
            auto elem = Node.newTable(Origin.explicit);
            if (existing is null)
            {
                auto arr = Node.newArray(true);
                arr.items ~= elem;
                t.members[last] = arr;
            }
            else if ((*existing).kind == Kind.array && (*existing).isTableArray)
                (*existing).items ~= elem;
            else
                fail("not an array of tables");
            cur = elem;
        }
    }

    /// One intermediate segment of a header path.
    Node stepHeader(Node t, string seg)
    {
        if (auto e = seg in t.members)
        {
            auto n = *e;
            if (n.kind == Kind.table)
            {
                if (n.origin == Origin.inline)
                    fail("cannot extend inline table");
                return n;
            }
            if (n.kind == Kind.array && n.isTableArray)
                return n.items[$ - 1];
            fail("key is not a table");
        }
        auto n = Node.newTable(Origin.implicit);
        t.members[seg] = n;
        return n;
    }

    /// Parses `key = value` and stores it in `table`.
    void parseKeyValue(Node table)
    {
        auto segs = parseKey();
        skipWs();
        if (p >= s.length || s[p] != '=')
            fail("expected =");
        p++;
        skipWs();

        Node t = table;
        foreach (seg; segs[0 .. $ - 1])
        {
            if (auto e = seg in t.members)
            {
                auto n = *e;
                if (n.kind != Kind.table || n.origin == Origin.explicit || n.origin == Origin.inline)
                    fail("cannot extend table with dotted key");
                t = n;
            }
            else
            {
                auto n = Node.newTable(Origin.dotted);
                t.members[seg] = n;
                t = n;
            }
        }
        immutable last = segs[$ - 1];
        if (last in t.members)
            fail("duplicate key");
        t.members[last] = parseValue();
    }

    // ------------------------------------------------------------------
    // values

    Node parseValue()
    {
        if (p >= s.length)
            fail("expected value");
        switch (s[p])
        {
        case '"':
            if (p + 2 < s.length && s[p + 1] == '"' && s[p + 2] == '"')
                return Node.fromString(parseMultiBasic());
            return Node.fromString(parseBasicString());
        case '\'':
            if (p + 2 < s.length && s[p + 1] == '\'' && s[p + 2] == '\'')
                return Node.fromString(parseMultiLiteral());
            return Node.fromString(parseLiteralString());
        case '[':
            return parseArray();
        case '{':
            return parseInlineTable();
        default:
            return parseScalar();
        }
    }

    Node parseArray()
    {
        p++;
        auto arr = Node.newArray(false);
        for (;;)
        {
            skipWsNlComments();
            if (p >= s.length)
                fail("unterminated array");
            if (s[p] == ']')
            {
                p++;
                return arr;
            }
            arr.items ~= parseValue();
            skipWsNlComments();
            if (p >= s.length)
                fail("unterminated array");
            if (s[p] == ',')
                p++;
            else if (s[p] != ']')
                fail("expected , or ]");
        }
    }

    Node parseInlineTable()
    {
        p++;
        auto t = Node.newTable(Origin.explicit);
        skipWs();
        if (p < s.length && s[p] == '}')
        {
            p++;
            t.origin = Origin.inline;
            return t;
        }
        for (;;)
        {
            skipWs();
            parseKeyValue(t);
            skipWs();
            if (p >= s.length)
                fail("unterminated inline table");
            if (s[p] == ',')
            {
                p++;
                continue;
            }
            if (s[p] == '}')
            {
                p++;
                break;
            }
            fail("expected , or }");
        }
        seal(t);
        return t;
    }

    /// Marks an inline table, and every dotted table created inside it, closed.
    static void seal(Node t)
    {
        t.origin = Origin.inline;
        foreach (child; t.members.byValue)
            if (child.kind == Kind.table && child.origin == Origin.dotted)
                seal(child);
    }

    // ------------------------------------------------------------------
    // strings

    /// Reads exactly `n` hex digits and returns the code point.
    uint readHex(size_t n)
    {
        if (p + n > s.length)
            fail("bad unicode escape");
        uint v = 0;
        foreach (i; 0 .. n)
        {
            immutable c = s[p + i];
            if (!isHex(c))
                fail("bad unicode escape", p + i);
            v = (v << 4) | hexVal(c);
        }
        p += n;
        if (!isScalarValue(v))
            fail("unicode escape is not a scalar value");
        return v;
    }

    /// Decodes the escape whose backslash was just consumed.
    void parseEscape(ref char[] buf)
    {
        if (p >= s.length)
            fail("unterminated escape");
        immutable c = s[p++];
        switch (c)
        {
        case 'b':
            buf ~= '\b';
            break;
        case 't':
            buf ~= '\t';
            break;
        case 'n':
            buf ~= '\n';
            break;
        case 'f':
            buf ~= '\f';
            break;
        case 'r':
            buf ~= '\r';
            break;
        case '"':
            buf ~= '"';
            break;
        case '\\':
            buf ~= '\\';
            break;
        case 'u':
            appendUtf8(buf, readHex(4));
            break;
        case 'U':
            appendUtf8(buf, readHex(8));
            break;
        default:
            fail("invalid escape", p - 1);
        }
    }

    string parseBasicString()
    {
        p++; // opening quote
        size_t start = p;
        char[] buf;
        bool useBuf = false;
        for (;;)
        {
            while (p < s.length)
            {
                immutable c = s[p];
                if (c == '"' || c == '\\' || (c < 0x20 && c != '\t') || c == 0x7F)
                    break;
                p++;
            }
            if (p >= s.length)
                fail("unterminated string");
            immutable c = s[p];
            if (c == '"')
            {
                string result = useBuf ? (buf ~= s[start .. p]).idup : s[start .. p];
                p++;
                return result;
            }
            if (c == '\\')
            {
                if (!useBuf)
                {
                    useBuf = true;
                    buf = null;
                }
                buf ~= s[start .. p];
                p++;
                parseEscape(buf);
                start = p;
                continue;
            }
            fail("invalid character in string");
        }
    }

    string parseLiteralString()
    {
        p++;
        immutable start = p;
        while (p < s.length)
        {
            immutable c = s[p];
            if (c == '\'')
            {
                immutable r = s[start .. p];
                p++;
                return r;
            }
            if ((c < 0x20 && c != '\t') || c == 0x7F)
                fail("invalid character in literal string");
            p++;
        }
        fail("unterminated string");
    }

    string parseMultiBasic()
    {
        p += 3;
        acceptNewline();
        char[] buf;
        for (;;)
        {
            immutable start = p;
            while (p < s.length)
            {
                immutable c = s[p];
                if (c == '"' || c == '\\' || c == '\r' || (c < 0x20 && c != '\t' && c != '\n') || c == 0x7F)
                    break;
                p++;
            }
            buf ~= s[start .. p];
            if (p >= s.length)
                fail("unterminated string");
            immutable c = s[p];
            if (c == '"')
            {
                size_t n = 0;
                while (p + n < s.length && s[p + n] == '"')
                    n++;
                if (n < 3)
                {
                    foreach (_; 0 .. n)
                        buf ~= '"';
                    p += n;
                    continue;
                }
                if (n > 5)
                    fail("too many quotes");
                foreach (_; 0 .. n - 3)
                    buf ~= '"';
                p += n;
                return buf.idup;
            }
            if (c == '\r')
            {
                // validated: always CRLF
                buf ~= '\n';
                p += 2;
                continue;
            }
            if (c == '\\')
            {
                p++;
                // line-ending backslash?
                size_t q = p;
                while (q < s.length && (s[q] == ' ' || s[q] == '\t'))
                    q++;
                if (q < s.length && (s[q] == '\n' || (s[q] == '\r' && q + 1 < s.length && s[q + 1] == '\n')))
                {
                    p = q;
                    while (p < s.length && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n'
                            || (s[p] == '\r' && p + 1 < s.length && s[p + 1] == '\n')))
                        p += (s[p] == '\r') ? 2 : 1;
                    continue;
                }
                parseEscape(buf);
                continue;
            }
            fail("invalid character in string");
        }
    }

    string parseMultiLiteral()
    {
        p += 3;
        acceptNewline();
        char[] buf;
        for (;;)
        {
            immutable start = p;
            while (p < s.length)
            {
                immutable c = s[p];
                if (c == '\'' || c == '\r' || (c < 0x20 && c != '\t' && c != '\n') || c == 0x7F)
                    break;
                p++;
            }
            buf ~= s[start .. p];
            if (p >= s.length)
                fail("unterminated string");
            immutable c = s[p];
            if (c == '\'')
            {
                size_t n = 0;
                while (p + n < s.length && s[p + n] == '\'')
                    n++;
                if (n < 3)
                {
                    foreach (_; 0 .. n)
                        buf ~= '\'';
                    p += n;
                    continue;
                }
                if (n > 5)
                    fail("too many quotes");
                foreach (_; 0 .. n - 3)
                    buf ~= '\'';
                p += n;
                return buf.idup;
            }
            if (c == '\r')
            {
                buf ~= '\n';
                p += 2;
                continue;
            }
            fail("invalid character in literal string");
        }
    }

    // ------------------------------------------------------------------
    // scalars: booleans, numbers, date-times

    static bool isTokenEnd(char c) pure nothrow @nogc
    {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '#' || c == ',' || c == ']' || c == '}';
    }

    Node parseScalar()
    {
        immutable start = p;
        while (p < s.length && !isTokenEnd(s[p]))
            p++;
        // A date followed by a space and a complete-looking time is one token.
        if (p - start == 10 && p + 3 < s.length && s[p] == ' ' && isDigit(s[p + 1])
                && isDigit(s[p + 2]) && s[p + 3] == ':' && looksLikeDate(s[start .. p]))
        {
            p++;
            while (p < s.length && !isTokenEnd(s[p]))
                p++;
        }
        auto tok = s[start .. p];
        if (tok.length == 0)
            fail("expected value", start);
        if (tok == "true")
            return Node.newScalar(Kind.boolean, "true");
        if (tok == "false")
            return Node.newScalar(Kind.boolean, "false");
        if (looksLikeDate(tok))
            return parseDateTime(tok, start);
        if (tok.length >= 3 && isDigit(tok[0]) && isDigit(tok[1]) && tok[2] == ':')
            return parseDateTime(tok, start);
        return parseNumber(tok, start);
    }

    static bool looksLikeDate(const(char)[] t) pure nothrow @nogc
    {
        return t.length >= 5 && isDigit(t[0]) && isDigit(t[1]) && isDigit(t[2]) && isDigit(t[3]) && t[4] == '-';
    }

    // ---- numbers

    Node parseNumber(string tok, size_t at)
    {
        size_t i = 0;
        bool neg = false, signed = false;
        if (tok[0] == '+' || tok[0] == '-')
        {
            neg = tok[0] == '-';
            signed = true;
            i = 1;
        }
        auto rest = tok[i .. $];
        if (rest == "inf")
            return Node.newScalar(Kind.float_, neg ? "-inf" : "inf");
        if (rest == "nan")
            return Node.newScalar(Kind.float_, "nan");

        if (!signed && tok.length > 2 && tok[0] == '0' && (tok[1] == 'x' || tok[1] == 'o' || tok[1] == 'b'))
            return parsePrefixedInt(tok, at);

        // decimal integer part
        size_t j = i;
        if (j >= tok.length || !isDigit(tok[j]))
            fail("invalid number", at);
        if (tok[j] == '0')
            j++;
        else
        {
            j++;
            j = skipDigits(tok, j, at);
        }
        if (j == tok.length)
        {
            // integer
            return Node.newScalar(Kind.integer, decimalInt(tok[i .. j], neg, at));
        }
        // float
        scratch.length = 0;
        if (neg)
            scratch ~= '-';
        scratch ~= tok[i .. j];
        stripUnderscoresInPlace();
        if (tok[j] == '.')
        {
            j++;
            immutable fs = j;
            if (j >= tok.length || !isDigit(tok[j]))
                fail("invalid float", at);
            j = skipDigits(tok, j, at);
            scratch ~= '.';
            scratch ~= tok[fs .. j];
        }
        if (j < tok.length && (tok[j] == 'e' || tok[j] == 'E'))
        {
            j++;
            scratch ~= 'e';
            if (j < tok.length && (tok[j] == '+' || tok[j] == '-'))
                scratch ~= tok[j++];
            immutable es = j;
            if (j >= tok.length || !isDigit(tok[j]))
                fail("invalid float", at);
            j = skipDigits(tok, j, at);
            scratch ~= tok[es .. j];
        }
        if (j != tok.length)
            fail("invalid number", at);
        // remove digit separators from what was appended after the int part
        stripUnderscoresInPlace();
        immutable v = parseFloatDecimal(scratch);
        return Node.newScalar(Kind.float_, formatFloat(v));
    }

    void stripUnderscoresInPlace()
    {
        size_t w = 0;
        foreach (c; scratch)
            if (c != '_')
                scratch[w++] = c;
        scratch.length = w;
    }

    /// Skips `(_? digit)*` starting at `j`; an underscore must be followed by a digit.
    size_t skipDigits(string tok, size_t j, size_t at)
    {
        while (j < tok.length)
        {
            immutable c = tok[j];
            if (isDigit(c))
                j++;
            else if (c == '_')
            {
                if (j + 1 >= tok.length || !isDigit(tok[j + 1]))
                    fail("invalid underscore", at);
                j += 2;
            }
            else
                break;
        }
        return j;
    }

    string decimalInt(const(char)[] digits, bool neg, size_t at)
    {
        ulong mag = 0;
        foreach (c; digits)
        {
            if (c == '_')
                continue;
            immutable d = c - '0';
            if (mag > (ulong.max - d) / 10)
                fail("integer out of range", at);
            mag = mag * 10 + d;
        }
        return intText(mag, neg, at);
    }

    string intText(ulong mag, bool neg, size_t at)
    {
        import std.conv : to;

        if (neg ? mag > (cast(ulong) long.max) + 1 : mag > long.max)
            fail("integer out of range", at);
        if (mag == 0)
            return "0";
        return neg ? "-" ~ mag.to!string : mag.to!string;
    }

    Node parsePrefixedInt(string tok, size_t at)
    {
        immutable base = tok[1] == 'x' ? 16 : tok[1] == 'o' ? 8 : 2;
        size_t j = 2;
        ulong mag = 0;
        bool prevDigit = false;
        for (; j < tok.length; j++)
        {
            immutable c = tok[j];
            if (c == '_')
            {
                if (!prevDigit || j + 1 >= tok.length)
                    fail("invalid underscore", at);
                prevDigit = false;
                continue;
            }
            int d;
            if (base == 16)
            {
                if (!isHex(c))
                    fail("invalid hex digit", at);
                d = hexVal(c);
            }
            else
            {
                if (c < '0' || c >= '0' + base)
                    fail("invalid digit", at);
                d = c - '0';
            }
            if (mag > (ulong.max - d) / base)
                fail("integer out of range", at);
            mag = mag * base + d;
            prevDigit = true;
        }
        if (!prevDigit)
            fail("invalid integer", at);
        return Node.newScalar(Kind.integer, intText(mag, false, at));
    }

    // ---- date-times

    static int num(const(char)[] t, size_t i, size_t n) pure nothrow @nogc
    {
        int v = 0;
        foreach (k; 0 .. n)
            v = v * 10 + (t[i + k] - '0');
        return v;
    }

    static bool digitsAt(const(char)[] t, size_t i, size_t n) pure nothrow @nogc
    {
        if (i + n > t.length)
            return false;
        foreach (k; 0 .. n)
            if (!isDigit(t[i + k]))
                return false;
        return true;
    }

    static bool validDate(const(char)[] t) pure nothrow @nogc
    {
        // t is exactly YYYY-MM-DD
        if (!digitsAt(t, 0, 4) || t[4] != '-' || !digitsAt(t, 5, 2) || t[7] != '-' || !digitsAt(t, 8, 2))
            return false;
        immutable y = num(t, 0, 4), m = num(t, 5, 2), d = num(t, 8, 2);
        if (y < 1 || m < 1 || m > 12 || d < 1)
            return false;
        static immutable int[12] dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        int maxd = dim[m - 1];
        if (m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)))
            maxd = 29;
        return d <= maxd;
    }

    /// Validates `HH:MM:SS[.frac]` at the start of `t`; returns its length or 0.
    static size_t validTime(const(char)[] t) pure nothrow @nogc
    {
        if (!digitsAt(t, 0, 2) || t.length < 8 || t[2] != ':' || !digitsAt(t, 3, 2) || t[5] != ':'
                || !digitsAt(t, 6, 2))
            return 0;
        if (num(t, 0, 2) > 23 || num(t, 3, 2) > 59 || num(t, 6, 2) > 59)
            return 0;
        size_t i = 8;
        if (i < t.length && t[i] == '.')
        {
            i++;
            immutable fs = i;
            while (i < t.length && isDigit(t[i]))
                i++;
            if (i == fs)
                return 0;
        }
        return i;
    }

    /// Canonical `HH:MM:SS[.frac]` with trailing fraction zeros removed.
    static string canonTime(const(char)[] t) pure nothrow
    {
        size_t end = t.length;
        if (end > 8)
        {
            while (end > 9 && t[end - 1] == '0')
                end--;
            if (end == 9) // only the '.' is left
                end = 8;
        }
        return t[0 .. end].idup;
    }

    Node parseDateTime(string tok, size_t at)
    {
        if (!looksLikeDate(tok))
        {
            // time-local
            immutable n = validTime(tok);
            if (n == 0 || n != tok.length)
                fail("invalid time", at);
            return Node.newScalar(Kind.timeLocal, canonTime(tok));
        }
        if (tok.length < 10 || !validDate(tok[0 .. 10]))
            fail("invalid date", at);
        if (tok.length == 10)
            return Node.newScalar(Kind.dateLocal, tok);
        immutable sep = tok[10];
        if (sep != 'T' && sep != 't' && sep != ' ')
            fail("invalid date-time", at);
        auto rest = tok[11 .. $];
        immutable tn = validTime(rest);
        if (tn == 0)
            fail("invalid time", at);
        auto timeText = canonTime(rest[0 .. tn]);
        auto datePart = tok[0 .. 10];
        if (tn == rest.length)
            return Node.newScalar(Kind.datetimeLocal, datePart ~ "T" ~ timeText);
        auto off = rest[tn .. $];
        string offText;
        if (off == "Z" || off == "z")
            offText = "Z";
        else
        {
            if (off.length != 6 || (off[0] != '+' && off[0] != '-') || !digitsAt(off, 1, 2)
                    || off[3] != ':' || !digitsAt(off, 4, 2) || num(off, 1, 2) > 23 || num(off, 4, 2) > 59)
                fail("invalid offset", at);
            offText = (num(off, 1, 2) == 0 && num(off, 4, 2) == 0) ? "Z" : off;
        }
        return Node.newScalar(Kind.datetime, datePart ~ "T" ~ timeText ~ offText);
    }
}

/// Single-pass recursive-descent TOML 1.0.0 parser.
module toml.parser;

import toml.datetime;
import toml.exception;
import toml.node;
import toml.number;
import toml.utf8;

/**
 * Parses a TOML 1.0.0 document.
 *
 * Params:
 *   document = the complete document as UTF-8 text
 * Returns: the root table.
 * Throws: `TomlException` if the document is not valid TOML.
 */
Node parseToml(string document)
{
    validateDocument(document);
    auto p = Parser(document);
    return p.parseDocument();
}

private:

bool isDigit(char c) pure nothrow @safe @nogc { return c >= '0' && c <= '9'; }

bool isBareKeyChar(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

/// Characters that end a bare scalar token.
bool isTokenEnd(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' || c == ']' || c == '}' || c == '#';
}

/// C0 controls other than tab, and DEL, are forbidden in strings and comments.
bool isForbidden(char c) pure nothrow @safe @nogc
{
    return (c < 0x20 && c != '\t') || c == 0x7F;
}

int hexVal(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

void appendUtf8(ref char[] o, uint cp) pure nothrow @safe
{
    if (cp < 0x80) o ~= cast(char) cp;
    else if (cp < 0x800)
    {
        o ~= cast(char)(0xC0 | (cp >> 6));
        o ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        o ~= cast(char)(0xE0 | (cp >> 12));
        o ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        o ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        o ~= cast(char)(0xF0 | (cp >> 18));
        o ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        o ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        o ~= cast(char)(0x80 | (cp & 0x3F));
    }
}

struct Parser
{
    string src;
    size_t pos;
    Node root;
    Node cur;
    char[] scratch;

    this(string s)
    {
        src = s;
    }

    noreturn fail(string msg = "invalid TOML") const
    {
        throw new TomlException(msg, pos);
    }

    // ---------------------------------------------------------------- lines

    Node parseDocument()
    {
        root = Node.newTable();
        root.explicit_ = true;
        cur = root;
        immutable n = src.length;
        while (true)
        {
            skipWs();
            if (pos >= n) break;
            immutable c = src[pos];
            if (c != '#' && c != '\n' && c != '\r')
            {
                if (c == '[') parseHeader();
                else parseKeyValue(cur);
                skipWs();
            }
            if (pos < n && src[pos] == '#') skipComment();
            if (pos >= n) break;
            if (src[pos] == '\n') pos++;
            else if (src[pos] == '\r') pos += 2; // CR is always followed by LF (prevalidated)
            else fail("expected end of line");
        }
        return root;
    }

    void skipWs()
    {
        while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t')) pos++;
    }

    /// Skips a comment up to (not including) the line break.
    void skipComment()
    {
        pos++; // '#'
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\n' || c == '\r') break;
            if (isForbidden(c)) fail("control character in comment");
            pos++;
        }
    }

    /// Skips whitespace, comments and line breaks (inside arrays).
    void skipWsNlComments()
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\t' || c == '\n') pos++;
            else if (c == '\r') pos += 2;
            else if (c == '#') skipComment();
            else break;
        }
    }

    // ----------------------------------------------------------------- keys

    string parseSimpleKey()
    {
        if (pos >= src.length) fail("expected key");
        immutable c = src[pos];
        if (c == '"') { pos++; return parseBasicString(); }
        if (c == '\'') { pos++; return parseLiteralString(); }
        immutable st = pos;
        while (pos < src.length && isBareKeyChar(src[pos])) pos++;
        if (pos == st) fail("expected key");
        return src[st .. pos];
    }

    /// Parses `key = value` (key possibly dotted) and stores it into `base`.
    void parseKeyValue(Node base)
    {
        Node t = base;
        string seg = parseSimpleKey();
        while (true)
        {
            skipWs();
            if (pos < src.length && src[pos] == '.')
            {
                pos++;
                skipWs();
                t = descendDotted(t, seg);
                seg = parseSimpleKey();
            }
            else break;
        }
        if (pos >= src.length || src[pos] != '=') fail("expected '='");
        pos++;
        skipWs();
        auto v = parseValue();
        if (seg in t.members) fail("duplicate key");
        t.members[seg] = v;
    }

    // --------------------------------------------------------------- tables

    Node descendDotted(Node t, string seg)
    {
        if (auto p = seg in t.members)
        {
            auto n = *p;
            if (n.kind != Kind.table || n.explicit_ || n.sealed) fail("cannot extend table with dotted key");
            return n;
        }
        auto n = Node.newTable();
        n.dotted = true;
        t.members[seg] = n;
        return n;
    }

    Node descendHeader(Node t, string seg)
    {
        if (auto p = seg in t.members)
        {
            auto n = *p;
            if (n.kind == Kind.table)
            {
                if (n.sealed) fail("header passes through inline table");
                return n;
            }
            if (n.kind == Kind.array && n.aot) return n.elements[$ - 1];
            fail("header passes through non-table");
        }
        auto n = Node.newTable();
        t.members[seg] = n;
        return n;
    }

    void parseHeader()
    {
        pos++; // '['
        bool isArray = false;
        if (pos < src.length && src[pos] == '[')
        {
            isArray = true;
            pos++;
        }
        skipWs();
        Node t = root;
        string seg = parseSimpleKey();
        while (true)
        {
            skipWs();
            if (pos < src.length && src[pos] == '.')
            {
                pos++;
                skipWs();
                t = descendHeader(t, seg);
                seg = parseSimpleKey();
            }
            else break;
        }
        if (pos >= src.length || src[pos] != ']') fail("expected ']'");
        pos++;
        if (isArray)
        {
            if (pos >= src.length || src[pos] != ']') fail("expected ']]'");
            pos++;
        }

        auto p = seg in t.members;
        if (isArray)
        {
            Node arr;
            if (p is null)
            {
                arr = Node.newArray();
                arr.aot = true;
                t.members[seg] = arr;
            }
            else
            {
                arr = *p;
                if (arr.kind != Kind.array || !arr.aot) fail("not an array of tables");
            }
            auto el = Node.newTable();
            el.explicit_ = true;
            arr.elements ~= el;
            cur = el;
        }
        else
        {
            if (p is null)
            {
                auto n = Node.newTable();
                n.explicit_ = true;
                t.members[seg] = n;
                cur = n;
            }
            else
            {
                auto n = *p;
                if (n.kind != Kind.table || n.explicit_ || n.dotted || n.sealed) fail("table redefined");
                n.explicit_ = true;
                cur = n;
            }
        }
    }

    /// Marks an inline table and every table created inside it as closed.
    void seal(Node t)
    {
        t.sealed = true;
        foreach (c; t.members.byValue)
            if (c.kind == Kind.table && !c.sealed) seal(c);
    }

    // --------------------------------------------------------------- values

    Node parseValue()
    {
        if (pos >= src.length) fail("expected value");
        switch (src[pos])
        {
        case '"':
            if (src.length - pos >= 3 && src[pos + 1] == '"' && src[pos + 2] == '"')
            {
                pos += 3;
                return Node.fromString(parseMultiBasicString());
            }
            pos++;
            return Node.fromString(parseBasicString());
        case '\'':
            if (src.length - pos >= 3 && src[pos + 1] == '\'' && src[pos + 2] == '\'')
            {
                pos += 3;
                return Node.fromString(parseMultiLiteralString());
            }
            pos++;
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
        pos++; // '['
        auto a = Node.newArray();
        while (true)
        {
            skipWsNlComments();
            if (pos >= src.length) fail("unterminated array");
            if (src[pos] == ']') { pos++; return a; }
            a.elements ~= parseValue();
            skipWsNlComments();
            if (pos >= src.length) fail("unterminated array");
            immutable c = src[pos];
            if (c == ',') pos++;
            else if (c == ']') { pos++; return a; }
            else fail("expected ',' or ']'");
        }
    }

    Node parseInlineTable()
    {
        pos++; // '{'
        auto t = Node.newTable();
        t.explicit_ = true;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            pos++;
            t.sealed = true;
            return t;
        }
        while (true)
        {
            parseKeyValue(t);
            skipWs();
            if (pos >= src.length) fail("unterminated inline table");
            immutable c = src[pos];
            if (c == ',') { pos++; skipWs(); }
            else if (c == '}') { pos++; seal(t); return t; }
            else fail("expected ',' or '}'");
        }
    }

    /// Booleans, numbers and date-times.
    Node parseScalar()
    {
        immutable st = pos;
        while (pos < src.length && !isTokenEnd(src[pos])) pos++;
        if (pos == st) fail("expected value");
        // "1979-05-27 07:32:00": a space joins a date and a time only if a time follows.
        if (pos - st == 10 && looksLikeDate(src[st .. pos]) && pos + 3 < src.length
            && src[pos] == ' ' && looksLikeTime(src[pos + 1 .. $]))
        {
            pos++;
            while (pos < src.length && !isTokenEnd(src[pos])) pos++;
        }
        auto tok = src[st .. pos];
        if (tok == "true") return Node.fromBool(true);
        if (tok == "false") return Node.fromBool(false);
        Kind k;
        string text;
        if (looksLikeDate(tok) || looksLikeTime(tok))
        {
            if (!parseDateTime(tok, k, text)) fail("invalid date-time");
        }
        else if (!parseNumber(tok, k, text)) fail("invalid value");
        return Node.newScalar(k, text);
    }

    // -------------------------------------------------------------- strings

    string parseLiteralString()
    {
        immutable st = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\'')
            {
                auto s = src[st .. pos];
                pos++;
                return s;
            }
            if (isForbidden(c)) fail("invalid character in literal string");
            pos++;
        }
        fail("unterminated string");
    }

    string parseBasicString()
    {
        immutable st = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                auto s = src[st .. pos];
                pos++;
                return s;
            }
            if (c == '\\') break;
            if (isForbidden(c)) fail("invalid character in string");
            pos++;
        }
        if (pos >= src.length) fail("unterminated string");
        // Slow path: escapes present.
        scratch.length = 0;
        assumeSafeAppend(scratch);
        scratch ~= src[st .. pos];
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                pos++;
                return scratch.idup;
            }
            if (c == '\\')
            {
                pos++;
                parseEscape();
            }
            else
            {
                if (isForbidden(c)) fail("invalid character in string");
                scratch ~= c;
                pos++;
            }
        }
        fail("unterminated string");
    }

    /// Decodes the escape whose backslash has just been consumed, appending to `scratch`.
    void parseEscape()
    {
        if (pos >= src.length) fail("bad escape");
        immutable c = src[pos++];
        switch (c)
        {
        case 'b': scratch ~= '\b'; break;
        case 't': scratch ~= '\t'; break;
        case 'n': scratch ~= '\n'; break;
        case 'f': scratch ~= '\f'; break;
        case 'r': scratch ~= '\r'; break;
        case '"': scratch ~= '"'; break;
        case '\\': scratch ~= '\\'; break;
        case 'u': case 'U':
            immutable digits = c == 'u' ? 4 : 8;
            if (src.length - pos < digits) fail("bad unicode escape");
            uint cp = 0;
            foreach (i; 0 .. digits)
            {
                immutable h = hexVal(src[pos + i]);
                if (h < 0) fail("bad unicode escape");
                cp = (cp << 4) | h;
            }
            pos += digits;
            if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) fail("invalid code point");
            appendUtf8(scratch, cp);
            break;
        default:
            pos--;
            fail("invalid escape");
        }
    }

    /// Skips the newline directly after an opening multi-line delimiter.
    void skipLeadingNewline()
    {
        if (pos < src.length)
        {
            if (src[pos] == '\n') pos++;
            else if (src[pos] == '\r') pos += 2;
        }
    }

    /// Counts the run of `q` characters at `pos` and advances past it.
    size_t quoteRun(char q)
    {
        immutable st = pos;
        while (pos < src.length && src[pos] == q) pos++;
        return pos - st;
    }

    string parseMultiBasicString()
    {
        skipLeadingNewline();
        scratch.length = 0;
        assumeSafeAppend(scratch);
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                immutable n = quoteRun('"');
                if (n < 3)
                    foreach (_; 0 .. n) scratch ~= '"';
                else if (n > 5) fail("too many quotes");
                else
                {
                    foreach (_; 0 .. n - 3) scratch ~= '"';
                    return scratch.idup;
                }
            }
            else if (c == '\\')
            {
                pos++;
                // Line-ending backslash?
                size_t p = pos;
                while (p < src.length && (src[p] == ' ' || src[p] == '\t')) p++;
                if (p < src.length && (src[p] == '\n' || src[p] == '\r'))
                {
                    pos = p;
                    while (pos < src.length)
                    {
                        immutable d = src[pos];
                        if (d == ' ' || d == '\t' || d == '\n') pos++;
                        else if (d == '\r') pos += 2;
                        else break;
                    }
                }
                else parseEscape();
            }
            else if (c == '\r') { scratch ~= '\n'; pos += 2; }
            else if (c == '\n') { scratch ~= '\n'; pos++; }
            else
            {
                if (isForbidden(c)) fail("invalid character in string");
                scratch ~= c;
                pos++;
            }
        }
        fail("unterminated string");
    }

    string parseMultiLiteralString()
    {
        skipLeadingNewline();
        scratch.length = 0;
        assumeSafeAppend(scratch);
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\'')
            {
                immutable n = quoteRun('\'');
                if (n < 3)
                    foreach (_; 0 .. n) scratch ~= '\'';
                else if (n > 5) fail("too many quotes");
                else
                {
                    foreach (_; 0 .. n - 3) scratch ~= '\'';
                    return scratch.idup;
                }
            }
            else if (c == '\r') { scratch ~= '\n'; pos += 2; }
            else if (c == '\n') { scratch ~= '\n'; pos++; }
            else
            {
                if (isForbidden(c)) fail("invalid character in string");
                scratch ~= c;
                pos++;
            }
        }
        fail("unterminated string");
    }
}

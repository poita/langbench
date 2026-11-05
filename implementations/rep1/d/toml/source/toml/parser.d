/**
 * The TOML 1.0.0 decoder: a single-pass recursive-descent parser that builds a
 * $(REF Node, toml,node) tree.
 */
module toml.parser;

import std.array : Appender;
import toml.node;
import toml.scalar;
import toml.validate;

/**
 * Parses a TOML document.
 *
 * Params:
 *   document = the complete document text (bytes, validated as UTF-8 here)
 * Returns: the root table
 * Throws: $(REF TomlException, toml,node) if the document is not valid TOML 1.0.0
 */
Node parse(string document)
{
    validateDocument(document);
    auto p = new Parser(document);
    try
        return p.run();
    catch (TomlException e)
    {
        if (e.line == 0)
            e.line = lineOf(document, p.p);
        throw e;
    }
}

private:

bool isBareKeyChar(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '-';
}

final class Parser
{
    string s;
    size_t p;
    Node root;
    Node cur;
    Appender!(char[]) buf;

    this(string s) { this.s = s; }

    TomlException fail(string msg)
    {
        return new TomlException(msg);
    }

    char at(size_t i) const pure nothrow @safe @nogc
    {
        return i < s.length ? s[i] : '\0';
    }

    void skipWs()
    {
        while (p < s.length && (s[p] == ' ' || s[p] == '\t'))
            ++p;
    }

    /// Skips a comment; leaves `p` on the terminating newline (or at EOF).
    void skipComment()
    {
        ++p; // '#'
        while (p < s.length)
        {
            immutable c = s[p];
            if (c == '\n' || c == '\r')
                return;
            if ((c < 0x20 && c != '\t') || c == 0x7f)
                throw fail("control character in comment");
            ++p;
        }
    }

    /// Whitespace, newlines and comments (inside arrays).
    void skipBlank()
    {
        for (;;)
        {
            skipWs();
            if (p >= s.length) return;
            immutable c = s[p];
            if (c == '#') skipComment();
            else if (c == '\n') ++p;
            else if (c == '\r') p += 2;
            else return;
        }
    }

    Node run()
    {
        root = Node.newTable();
        cur = root;
        for (;;)
        {
            skipWs();
            if (p >= s.length) break;
            immutable c = s[p];
            if (c != '#' && c != '\n' && c != '\r')
            {
                if (c == '[') header();
                else keyValue(cur);
                skipWs();
            }
            if (p < s.length && s[p] == '#')
                skipComment();
            if (p >= s.length) break;
            if (s[p] == '\n') ++p;
            else if (s[p] == '\r') p += 2;
            else throw fail("expected end of line");
        }
        return root;
    }

    // ------------------------------------------------------------------ keys

    string[] parseKey()
    {
        string[] key;
        for (;;)
        {
            skipWs();
            key ~= simpleKey();
            skipWs();
            if (at(p) == '.')
            {
                ++p;
                continue;
            }
            return key;
        }
    }

    string simpleKey()
    {
        immutable c = at(p);
        if (c == '"')
        {
            ++p;
            return readString('"', false);
        }
        if (c == '\'')
        {
            ++p;
            return readString('\'', false);
        }
        immutable start = p;
        while (p < s.length && isBareKeyChar(s[p]))
            ++p;
        if (p == start)
            throw fail("invalid key");
        return s[start .. p];
    }

    // --------------------------------------------------------------- headers

    void header()
    {
        ++p;
        immutable isArr = at(p) == '[';
        if (isArr) ++p;
        auto key = parseKey();
        if (at(p) != ']') throw fail("expected ]");
        ++p;
        if (isArr)
        {
            if (at(p) != ']') throw fail("expected ]]");
            ++p;
        }
        Node t = root;
        foreach (seg; key[0 .. $ - 1])
        {
            if (auto c = seg in t.fields)
            {
                auto n = *c;
                if (n.kind == Kind.table && !n.sealed)
                    t = n;
                else if (n.kind == Kind.array && n.tableArray)
                    t = n.items[$ - 1];
                else
                    throw fail("cannot extend " ~ seg);
            }
            else
            {
                auto n = Node.newTable();
                t.fields[seg] = n;
                t = n;
            }
        }
        immutable last = key[$ - 1];
        auto c = last in t.fields;
        if (!isArr)
        {
            if (c is null)
            {
                auto n = Node.newTable();
                n.explicit = true;
                t.fields[last] = n;
                cur = n;
            }
            else
            {
                auto n = *c;
                if (n.kind != Kind.table || n.explicit || n.dotted || n.sealed)
                    throw fail("table redefined: " ~ last);
                n.explicit = true;
                cur = n;
            }
        }
        else
        {
            auto el = Node.newTable();
            el.explicit = true;
            if (c is null)
            {
                auto a = Node.newArray();
                a.tableArray = true;
                a.items ~= el;
                t.fields[last] = a;
            }
            else if (c.kind == Kind.array && c.tableArray)
                c.items ~= el;
            else
                throw fail("not an array of tables: " ~ last);
            cur = el;
        }
    }

    // ------------------------------------------------------------ key/values

    void keyValue(Node tbl)
    {
        auto key = parseKey();
        if (at(p) != '=') throw fail("expected =");
        ++p;
        skipWs();
        auto v = parseValue();
        foreach (seg; key[0 .. $ - 1])
        {
            if (auto c = seg in tbl.fields)
            {
                auto n = *c;
                if (n.kind != Kind.table || n.explicit || n.sealed)
                    throw fail("cannot extend " ~ seg);
                tbl = n;
            }
            else
            {
                auto n = Node.newTable();
                n.dotted = true;
                tbl.fields[seg] = n;
                tbl = n;
            }
        }
        immutable last = key[$ - 1];
        if (last in tbl.fields)
            throw fail("duplicate key: " ~ last);
        tbl.fields[last] = v;
    }

    // ---------------------------------------------------------------- values

    Node parseValue()
    {
        immutable c = at(p);
        switch (c)
        {
        case '"':
            if (at(p + 1) == '"' && at(p + 2) == '"')
            {
                p += 3;
                skipFirstNewline();
                return Node.scalar(Kind.string, readString('"', true));
            }
            ++p;
            return Node.scalar(Kind.string, readString('"', false));
        case '\'':
            if (at(p + 1) == '\'' && at(p + 2) == '\'')
            {
                p += 3;
                skipFirstNewline();
                return Node.scalar(Kind.string, readString('\'', true));
            }
            ++p;
            return Node.scalar(Kind.string, readString('\'', false));
        case '[':
            return parseArray();
        case '{':
            return parseInlineTable();
        case 't':
            if (s.length - p >= 4 && s[p .. p + 4] == "true")
            {
                p += 4;
                return Node.scalar(Kind.boolean, "true");
            }
            throw fail("invalid value");
        case 'f':
            if (s.length - p >= 5 && s[p .. p + 5] == "false")
            {
                p += 5;
                return Node.scalar(Kind.boolean, "false");
            }
            throw fail("invalid value");
        default:
            break;
        }
        if (looksLikeDate(s, p) || looksLikeTime(s, p))
            return parseDateTime(s, p);
        immutable start = p;
        while (p < s.length)
        {
            switch (s[p])
            {
            case ' ', '\t', '\r', '\n', ',', ']', '}', '#':
                goto done;
            default:
                ++p;
            }
        }
    done:
        return parseNumber(s[start .. p]);
    }

    void skipFirstNewline()
    {
        if (at(p) == '\n') ++p;
        else if (at(p) == '\r') p += 2;
    }

    Node parseArray()
    {
        ++p;
        auto a = Node.newArray();
        for (;;)
        {
            skipBlank();
            if (at(p) == ']')
            {
                ++p;
                return a;
            }
            a.items ~= parseValue();
            skipBlank();
            immutable c = at(p);
            if (c == ',') ++p;
            else if (c == ']')
            {
                ++p;
                return a;
            }
            else throw fail("expected , or ]");
        }
    }

    Node parseInlineTable()
    {
        ++p;
        auto t = Node.newTable();
        t.explicit = true;
        skipWs();
        if (at(p) == '}')
        {
            ++p;
            t.sealed = true;
            return t;
        }
        for (;;)
        {
            skipWs();
            keyValue(t);
            skipWs();
            immutable c = at(p);
            if (c == ',') ++p;
            else if (c == '}')
            {
                ++p;
                t.sealed = true;
                return t;
            }
            else throw fail("expected , or }");
        }
    }

    // --------------------------------------------------------------- strings

    /// Reads a string body; `p` is just after the opening delimiter (and after
    /// the discarded first newline for multi-line strings).
    string readString(char q, bool multiline)
    {
        immutable escapes = q == '"';
        size_t run = p;
        bool useBuf = false;
        for (;;)
        {
            if (p >= s.length)
                throw fail("unterminated string");
            immutable c = s[p];
            if (c == q)
            {
                if (!multiline)
                {
                    auto r = finish(run, p, useBuf);
                    ++p;
                    return r;
                }
                size_t n = 1;
                while (at(p + n) == q) ++n;
                if (n < 3)
                {
                    p += n;
                    continue;
                }
                if (n > 5)
                    throw fail("too many quotes");
                auto r = finish(run, p + (n - 3), useBuf);
                p += n;
                return r;
            }
            if (c == '\\' && escapes)
            {
                flush(run, useBuf);
                ++p;
                escape(multiline);
                run = p;
                continue;
            }
            if (c == '\r' && multiline)
            {
                flush(run, useBuf);
                buf.put('\n');
                p += 2;
                run = p;
                continue;
            }
            if (c == '\n' && multiline)
            {
                ++p;
                continue;
            }
            if ((c < 0x20 && c != '\t') || c == 0x7f)
                throw fail("control character in string");
            ++p;
        }
    }

    void flush(size_t run, ref bool useBuf)
    {
        if (!useBuf)
        {
            buf.clear();
            useBuf = true;
        }
        buf.put(s[run .. p]);
    }

    string finish(size_t run, size_t end, bool useBuf)
    {
        if (!useBuf)
            return s[run .. end];
        buf.put(s[run .. end]);
        return buf.data.idup;
    }

    void escape(bool multiline)
    {
        immutable c = at(p);
        switch (c)
        {
        case 'b': buf.put('\b'); ++p; return;
        case 't': buf.put('\t'); ++p; return;
        case 'n': buf.put('\n'); ++p; return;
        case 'f': buf.put('\f'); ++p; return;
        case 'r': buf.put('\r'); ++p; return;
        case '"': buf.put('"'); ++p; return;
        case '\\': buf.put('\\'); ++p; return;
        case 'u': ++p; putCodePoint(hex(4)); return;
        case 'U': ++p; putCodePoint(hex(8)); return;
        case ' ', '\t', '\r', '\n':
            if (!multiline) break;
            size_t q = p;
            while (at(q) == ' ' || at(q) == '\t') ++q;
            if (at(q) != '\n' && at(q) != '\r')
                break;
            while (q < s.length && (s[q] == ' ' || s[q] == '\t' || s[q] == '\n' || s[q] == '\r'))
                ++q;
            p = q;
            return;
        default:
            break;
        }
        throw fail("invalid escape");
    }

    uint hex(int digits)
    {
        uint v = 0;
        foreach (_; 0 .. digits)
        {
            immutable d = hexDigit(at(p));
            if (d < 0) throw fail("invalid unicode escape");
            v = v * 16 + d;
            ++p;
        }
        return v;
    }

    void putCodePoint(uint cp)
    {
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
            throw fail("invalid unicode scalar value");
        if (cp < 0x80)
            buf.put(cast(char) cp);
        else if (cp < 0x800)
        {
            buf.put(cast(char)(0xC0 | (cp >> 6)));
            buf.put(cast(char)(0x80 | (cp & 0x3F)));
        }
        else if (cp < 0x10000)
        {
            buf.put(cast(char)(0xE0 | (cp >> 12)));
            buf.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
            buf.put(cast(char)(0x80 | (cp & 0x3F)));
        }
        else
        {
            buf.put(cast(char)(0xF0 | (cp >> 18)));
            buf.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
            buf.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
            buf.put(cast(char)(0x80 | (cp & 0x3F)));
        }
    }
}

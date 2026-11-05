/**
 * Tagged JSON: the interchange format of the `toml-test` suite.
 *
 * $(LREF toTaggedJson) writes a tree as compact, key-sorted JSON in which every
 * scalar is `{"type":T,"value":TEXT}`; $(LREF fromTaggedJson) reads it back.
 */
module toml.json;

import std.array : Appender, appender;
import toml.node;
import toml.scalar : hexDigit;

/// Serialises a tree as compact tagged JSON with sorted keys (no trailing newline).
string toTaggedJson(Node root)
{
    auto o = appender!(char[])();
    writeNode(o, root);
    return cast(string) o.data;
}

private void writeNode(ref Appender!(char[]) o, Node n)
{
    final switch (n.kind)
    {
    case Kind.table:
        o.put('{');
        bool first = true;
        foreach (k; n.sortedKeys)
        {
            if (!first) o.put(',');
            first = false;
            writeString(o, k);
            o.put(':');
            writeNode(o, n.fields[k]);
        }
        o.put('}');
        break;
    case Kind.array:
        o.put('[');
        foreach (i, e; n.items)
        {
            if (i) o.put(',');
            writeNode(o, e);
        }
        o.put(']');
        break;
    case Kind.string, Kind.integer, Kind.float_, Kind.boolean, Kind.datetime,
         Kind.datetimeLocal, Kind.dateLocal, Kind.timeLocal:
        o.put(`{"type":"`);
        o.put(typeName(n.kind));
        o.put(`","value":`);
        writeString(o, n.text);
        o.put('}');
        break;
    }
}

private void writeString(ref Appender!(char[]) o, string s)
{
    static immutable hexd = "0123456789abcdef";
    o.put('"');
    size_t run = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\')
            continue;
        o.put(s[run .. i]);
        run = i + 1;
        switch (c)
        {
        case '"':  o.put(`\"`); break;
        case '\\': o.put(`\\`); break;
        case '\b': o.put(`\b`); break;
        case '\f': o.put(`\f`); break;
        case '\n': o.put(`\n`); break;
        case '\r': o.put(`\r`); break;
        case '\t': o.put(`\t`); break;
        default:
            o.put(`\u00`);
            o.put(hexd[c >> 4]);
            o.put(hexd[c & 15]);
        }
    }
    o.put(s[run .. $]);
    o.put('"');
}

/**
 * Parses tagged JSON into a tree.
 *
 * A JSON object is a scalar exactly when it has the two string members
 * `type` and `value` with a known type name; otherwise it is a table.
 * Scalar `value` texts are kept verbatim.
 * Throws: $(REF TomlException, toml,node) on malformed input.
 */
Node fromTaggedJson(string json)
{
    auto r = JsonReader(json);
    auto n = r.value();
    r.skipWs();
    if (r.p != json.length)
        throw new TomlException("trailing data after JSON value");
    return n;
}

private struct JsonReader
{
    string s;
    size_t p;
    Appender!(char[]) buf;

    this(string s) { this.s = s; }

    void skipWs()
    {
        while (p < s.length && (s[p] == ' ' || s[p] == '\t' || s[p] == '\n' || s[p] == '\r'))
            ++p;
    }

    TomlException fail(string m) { return new TomlException("JSON: " ~ m); }

    Node value()
    {
        skipWs();
        if (p >= s.length) throw fail("unexpected end");
        switch (s[p])
        {
        case '{': return object();
        case '[': return array();
        default: throw fail("unexpected character");
        }
    }

    Node array()
    {
        ++p;
        auto a = Node.newArray();
        skipWs();
        if (p < s.length && s[p] == ']')
        {
            ++p;
            return a;
        }
        for (;;)
        {
            a.items ~= value();
            skipWs();
            if (p >= s.length) throw fail("unterminated array");
            if (s[p] == ',') { ++p; continue; }
            if (s[p] == ']') { ++p; return a; }
            throw fail("expected , or ]");
        }
    }

    Node object()
    {
        ++p;
        auto t = Node.newTable();
        string[string] strs;
        skipWs();
        if (p < s.length && s[p] == '}')
        {
            ++p;
            return t;
        }
        for (;;)
        {
            skipWs();
            if (p >= s.length || s[p] != '"') throw fail("expected key");
            auto key = str();
            skipWs();
            if (p >= s.length || s[p] != ':') throw fail("expected :");
            ++p;
            skipWs();
            if (p < s.length && s[p] == '"')
                strs[key] = str();
            else
                t.fields[key] = value();
            skipWs();
            if (p >= s.length) throw fail("unterminated object");
            if (s[p] == ',') { ++p; continue; }
            if (s[p] == '}') { ++p; break; }
            throw fail("expected , or }");
        }
        if (strs.length == 0)
            return t;
        Kind k;
        if (t.fields.length == 0 && strs.length == 2)
        {
            auto ty = "type" in strs;
            auto va = "value" in strs;
            if (ty && va && scalarKindFromName(*ty, k))
                return Node.scalar(k, *va);
        }
        throw fail("bad value node");
    }

    string str()
    {
        ++p; // opening quote
        size_t run = p;
        bool useBuf = false;
        for (;;)
        {
            if (p >= s.length) throw fail("unterminated string");
            immutable c = s[p];
            if (c == '"')
            {
                string r;
                if (useBuf)
                {
                    buf.put(s[run .. p]);
                    r = buf.data.idup;
                }
                else
                    r = s[run .. p];
                ++p;
                return r;
            }
            if (c != '\\')
            {
                ++p;
                continue;
            }
            if (!useBuf)
            {
                buf.clear();
                useBuf = true;
            }
            buf.put(s[run .. p]);
            ++p;
            if (p >= s.length) throw fail("unterminated string");
            immutable e = s[p++];
            switch (e)
            {
            case '"': buf.put('"'); break;
            case '\\': buf.put('\\'); break;
            case '/': buf.put('/'); break;
            case 'b': buf.put('\b'); break;
            case 'f': buf.put('\f'); break;
            case 'n': buf.put('\n'); break;
            case 'r': buf.put('\r'); break;
            case 't': buf.put('\t'); break;
            case 'u':
                uint cp = hex4();
                if (cp >= 0xD800 && cp <= 0xDBFF && p + 1 < s.length && s[p] == '\\' && s[p + 1] == 'u')
                {
                    p += 2;
                    immutable lo = hex4();
                    if (lo < 0xDC00 || lo > 0xDFFF) throw fail("bad surrogate pair");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                putCodePoint(cp);
                break;
            default: throw fail("bad escape");
            }
            run = p;
        }
    }

    uint hex4()
    {
        uint v = 0;
        foreach (_; 0 .. 4)
        {
            immutable d = p < s.length ? hexDigit(s[p]) : -1;
            if (d < 0) throw fail("bad \\u escape");
            v = v * 16 + d;
            ++p;
        }
        return v;
    }

    void putCodePoint(uint cp)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF) throw fail("lone surrogate");
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

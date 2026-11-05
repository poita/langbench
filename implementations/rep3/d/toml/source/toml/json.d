/// The "tagged JSON" interchange format of the toml-test suite.
///
/// Tables are JSON objects, arrays are JSON arrays and scalars are
/// `{"type": ..., "value": ...}` objects whose value is always a string.
module toml.json;

import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import toml.exception;
import toml.node;

// ------------------------------------------------------------------ writer

/**
 * Renders `root` as compact tagged JSON with the keys of every object sorted
 * by code point. The result has no trailing newline.
 */
string toTaggedJson(Node root)
{
    auto o = appender!(char[]);
    o.reserve(4096);
    writeNode(o, root);
    return cast(string) o.data;
}

private:

void writeNode(ref Appender!(char[]) o, Node n)
{
    final switch (n.kind)
    {
    case Kind.table:
        o.put('{');
        auto keys = n.members.keys;
        keys.sort();
        bool first = true;
        foreach (k; keys)
        {
            if (!first) o.put(',');
            first = false;
            writeJsonString(o, k);
            o.put(':');
            writeNode(o, n.members[k]);
        }
        o.put('}');
        break;
    case Kind.array:
        o.put('[');
        foreach (i, e; n.elements)
        {
            if (i) o.put(',');
            writeNode(o, e);
        }
        o.put(']');
        break;
    case Kind.string_, Kind.integer, Kind.float_, Kind.boolean, Kind.offsetDateTime,
         Kind.localDateTime, Kind.localDate, Kind.localTime:
        o.put(`{"type":"`);
        o.put(typeName(n.kind));
        o.put(`","value":`);
        writeJsonString(o, n.text);
        o.put('}');
        break;
    }
}

void writeJsonString(ref Appender!(char[]) o, const(char)[] s)
{
    static immutable hexDigits = "0123456789abcdef";
    o.put('"');
    size_t run = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\') continue;
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
            o.put(hexDigits[c >> 4]);
            o.put(hexDigits[c & 15]);
        }
    }
    o.put(s[run .. $]);
    o.put('"');
}

// ------------------------------------------------------------------ reader

public:

/**
 * Parses tagged JSON into a tree. Scalar texts are kept verbatim.
 *
 * An object is a scalar exactly when it has the two string members `type`
 * (one of the eight type names) and `value`; every other object is a table.
 *
 * Throws: `TomlException` if the JSON is malformed.
 */
Node fromTaggedJson(string json)
{
    auto r = JsonReader(json);
    r.skipWs();
    string raw;
    auto n = r.parseValue(raw);
    if (n is null) throw new TomlException("expected object or array", r.pos);
    r.skipWs();
    if (r.pos != json.length) throw new TomlException("trailing data", r.pos);
    return n;
}

private:

struct Member
{
    string key;
    Node node;   // null when the member was a JSON string
    string raw;  // the JSON string when node is null
}

struct JsonReader
{
    string src;
    size_t pos;
    char[] scratch;

    noreturn fail(string msg = "invalid JSON") const
    {
        throw new TomlException(msg, pos);
    }

    void skipWs()
    {
        while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r'))
            pos++;
    }

    /// Parses a value; returns null and sets `raw` when it was a JSON string.
    Node parseValue(out string raw)
    {
        if (pos >= src.length) fail("unexpected end");
        switch (src[pos])
        {
        case '{': return parseObject();
        case '[': return parseArray();
        case '"':
            pos++;
            raw = parseString();
            return null;
        default:
            fail("unexpected character");
        }
    }

    Node parseArray()
    {
        pos++;
        auto a = Node.newArray();
        skipWs();
        if (pos < src.length && src[pos] == ']') { pos++; return a; }
        while (true)
        {
            skipWs();
            string raw;
            auto n = parseValue(raw);
            if (n is null) fail("string in array");
            a.elements ~= n;
            skipWs();
            if (pos >= src.length) fail("unterminated array");
            if (src[pos] == ',') pos++;
            else if (src[pos] == ']') { pos++; return a; }
            else fail("expected ',' or ']'");
        }
    }

    Node parseObject()
    {
        pos++;
        Member[] ms;
        skipWs();
        if (pos < src.length && src[pos] == '}') { pos++; return Node.newTable(); }
        while (true)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"') fail("expected key");
            pos++;
            Member m;
            m.key = parseString();
            skipWs();
            if (pos >= src.length || src[pos] != ':') fail("expected ':'");
            pos++;
            skipWs();
            m.node = parseValue(m.raw);
            ms ~= m;
            skipWs();
            if (pos >= src.length) fail("unterminated object");
            if (src[pos] == ',') pos++;
            else if (src[pos] == '}') { pos++; break; }
            else fail("expected ',' or '}'");
        }
        if (ms.length == 2)
        {
            Member* ty, va;
            foreach (ref m; ms)
            {
                if (m.key == "type") ty = &m;
                else if (m.key == "value") va = &m;
            }
            Kind k;
            if (ty && va && ty.node is null && va.node is null && kindFromTypeName(ty.raw, k))
                return Node.newScalar(k, va.raw);
        }
        auto t = Node.newTable();
        foreach (ref m; ms)
        {
            if (m.node is null) fail("string where table expected");
            t.members[m.key] = m.node;
        }
        return t;
    }

    uint hex4()
    {
        if (src.length - pos < 4) fail("bad \\u escape");
        uint v = 0;
        foreach (i; 0 .. 4)
        {
            immutable c = src[pos + i];
            uint d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else fail("bad \\u escape");
            v = v * 16 + d;
        }
        pos += 4;
        return v;
    }

    /// Parses the rest of a JSON string (opening quote already consumed).
    string parseString()
    {
        immutable st = pos;
        while (pos < src.length && src[pos] != '"' && src[pos] != '\\') pos++;
        if (pos >= src.length) fail("unterminated string");
        if (src[pos] == '"')
        {
            auto s = src[st .. pos];
            pos++;
            return s;
        }
        scratch.length = 0;
        assumeSafeAppend(scratch);
        scratch ~= src[st .. pos];
        while (true)
        {
            if (pos >= src.length) fail("unterminated string");
            immutable c = src[pos++];
            if (c == '"') return scratch.idup;
            if (c != '\\')
            {
                scratch ~= c;
                continue;
            }
            if (pos >= src.length) fail("bad escape");
            immutable e = src[pos++];
            switch (e)
            {
            case '"': scratch ~= '"'; break;
            case '\\': scratch ~= '\\'; break;
            case '/': scratch ~= '/'; break;
            case 'b': scratch ~= '\b'; break;
            case 'f': scratch ~= '\f'; break;
            case 'n': scratch ~= '\n'; break;
            case 'r': scratch ~= '\r'; break;
            case 't': scratch ~= '\t'; break;
            case 'u':
                uint cp = hex4();
                if (cp >= 0xD800 && cp <= 0xDBFF)
                {
                    if (src.length - pos < 2 || src[pos] != '\\' || src[pos + 1] != 'u') fail("lone surrogate");
                    pos += 2;
                    immutable lo = hex4();
                    if (lo < 0xDC00 || lo > 0xDFFF) fail("lone surrogate");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                else if (cp >= 0xDC00 && cp <= 0xDFFF) fail("lone surrogate");
                appendUtf8(cp);
                break;
            default:
                fail("bad escape");
            }
        }
    }

    void appendUtf8(uint cp)
    {
        if (cp < 0x80) scratch ~= cast(char) cp;
        else if (cp < 0x800)
        {
            scratch ~= cast(char)(0xC0 | (cp >> 6));
            scratch ~= cast(char)(0x80 | (cp & 0x3F));
        }
        else if (cp < 0x10000)
        {
            scratch ~= cast(char)(0xE0 | (cp >> 12));
            scratch ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
            scratch ~= cast(char)(0x80 | (cp & 0x3F));
        }
        else
        {
            scratch ~= cast(char)(0xF0 | (cp >> 18));
            scratch ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
            scratch ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
            scratch ~= cast(char)(0x80 | (cp & 0x3F));
        }
    }
}

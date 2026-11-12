/**
 * Reading and writing the `toml-test` "tagged JSON" interchange format.
 *
 * Tables are JSON objects, arrays are JSON arrays and scalars are
 * `{"type": ..., "value": ...}` objects whose members are both strings.
 */
module toml.json;

import std.array : Appender, appender;

import toml.node;
import toml.utf8 : encodeUtf8, isScalarValue;

/// Appends `s` as a JSON string literal (quotes included) to `sink`, escaping
/// only what JSON requires; non-ASCII is written literally as UTF-8.
void writeJsonString(ref Appender!string sink, const(char)[] s)
{
    static immutable hexDigits = "0123456789abcdef";
    sink.put('"');
    size_t runStart = 0;
    foreach (i, char c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\')
            continue;
        sink.put(s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"': sink.put(`\"`); break;
        case '\\': sink.put(`\\`); break;
        case '\b': sink.put(`\b`); break;
        case '\f': sink.put(`\f`); break;
        case '\n': sink.put(`\n`); break;
        case '\r': sink.put(`\r`); break;
        case '\t': sink.put(`\t`); break;
        default:
            sink.put(`\u00`);
            sink.put(hexDigits[c >> 4]);
            sink.put(hexDigits[c & 15]);
        }
    }
    sink.put(s[runStart .. $]);
    sink.put('"');
}

private void writeNode(ref Appender!string sink, Node n)
{
    final switch (n.kind)
    {
    case NodeKind.scalar:
        sink.put(`{"type":`);
        writeJsonString(sink, typeName(n.scalarType));
        sink.put(`,"value":`);
        writeJsonString(sink, n.text);
        sink.put('}');
        break;
    case NodeKind.array:
        sink.put('[');
        foreach (i, item; n.items)
        {
            if (i)
                sink.put(',');
            writeNode(sink, item);
        }
        sink.put(']');
        break;
    case NodeKind.table:
        sink.put('{');
        bool first = true;
        foreach (k; n.sortedKeys)
        {
            if (!first)
                sink.put(',');
            first = false;
            writeJsonString(sink, k);
            sink.put(':');
            writeNode(sink, n.entries[k]);
        }
        sink.put('}');
        break;
    }
}

/// Renders a tree as compact, key-sorted tagged JSON (no trailing newline).
string toTaggedJson(Node root)
{
    auto sink = appender!string();
    writeNode(sink, root);
    return sink.data;
}

/**
 * Parses tagged JSON into a `Node` tree.
 *
 * Whitespace and member order are free. Only objects, arrays and strings are
 * accepted (tagged JSON contains no other JSON types).
 *
 * Throws: `TomlException` on malformed input.
 */
Node fromTaggedJson(string json)
{
    auto r = JsonReader(json);
    r.skipWs();
    auto n = r.readValue();
    r.skipWs();
    if (r.pos != json.length)
        throw new TomlException("trailing data after JSON value", r.pos);
    return n;
}

private struct JsonReader
{
    string src;
    size_t pos;

    noreturn fail(string msg)
    {
        throw new TomlException(msg, pos);
    }

    void skipWs() @safe pure nothrow @nogc
    {
        while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'
                || src[pos] == '\n' || src[pos] == '\r'))
            pos++;
    }

    void expect(char c)
    {
        if (pos >= src.length || src[pos] != c)
            fail("expected '" ~ c ~ "'");
        pos++;
    }

    Node readValue()
    {
        if (pos >= src.length)
            fail("unexpected end of JSON");
        switch (src[pos])
        {
        case '{': return readObject();
        case '[': return readArray();
        case '"': return scalar(ScalarType.string_, readString());
        default: fail("unsupported JSON value");
        }
    }

    Node readArray()
    {
        pos++;
        auto arr = array();
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            pos++;
            return arr;
        }
        while (true)
        {
            skipWs();
            arr.items ~= readValue();
            skipWs();
            if (pos < src.length && src[pos] == ',')
                pos++;
            else
            {
                expect(']');
                return arr;
            }
        }
    }

    Node readObject()
    {
        pos++;
        auto t = table();
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            pos++;
            return t;
        }
        while (true)
        {
            skipWs();
            auto key = readString();
            skipWs();
            expect(':');
            skipWs();
            t.entries[key] = readValue();
            skipWs();
            if (pos < src.length && src[pos] == ',')
                pos++;
            else
            {
                expect('}');
                break;
            }
        }
        // A value node is an object with exactly two string members, `type`
        // and `value`, where `type` names a scalar type.
        if (t.entries.length == 2)
        {
            auto ty = "type" in t.entries;
            auto va = "value" in t.entries;
            ScalarType st;
            if (ty && va && ty.isScalar && va.isScalar && typeFromName(ty.text, st))
                return scalar(st, va.text);
        }
        return t;
    }

    uint readHex4()
    {
        if (pos + 4 > src.length)
            fail("truncated \\u escape");
        uint v = 0;
        foreach (k; 0 .. 4)
        {
            immutable c = src[pos + k];
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

    string readString()
    {
        expect('"');
        auto sink = appender!string();
        while (true)
        {
            if (pos >= src.length)
                fail("unterminated string");
            immutable c = src[pos++];
            if (c == '"')
                return sink.data;
            if (c != '\\')
            {
                sink.put(c);
                continue;
            }
            if (pos >= src.length)
                fail("unterminated escape");
            immutable e = src[pos++];
            switch (e)
            {
            case '"': sink.put('"'); break;
            case '\\': sink.put('\\'); break;
            case '/': sink.put('/'); break;
            case 'b': sink.put('\b'); break;
            case 'f': sink.put('\f'); break;
            case 'n': sink.put('\n'); break;
            case 'r': sink.put('\r'); break;
            case 't': sink.put('\t'); break;
            case 'u':
                uint cp = readHex4();
                if (cp >= 0xD800 && cp <= 0xDBFF && pos + 1 < src.length
                    && src[pos] == '\\' && src[pos + 1] == 'u')
                {
                    pos += 2;
                    immutable lo = readHex4();
                    if (lo < 0xDC00 || lo > 0xDFFF)
                        fail("bad surrogate pair");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                if (!isScalarValue(cp))
                    fail("lone surrogate");
                encodeUtf8(sink, cp);
                break;
            default:
                fail("bad escape");
            }
        }
    }
}

unittest
{
    auto n = fromTaggedJson(` { "b" : [ {"value":"1","type":"integer"} , {} ],
        "a": {"type":"string","value":"hé😀\n"} } `);
    assert(n.isTable);
    assert(n["a"].isScalar && n["a"].text == "hé😀\n");
    assert(n["b"].isArray && n["b"].items.length == 2);
    assert(n["b"].items[0].scalarType == ScalarType.integer);
    assert(n["b"].items[1].isTable);
    // Output is compact and key-sorted.
    assert(toTaggedJson(n) ==
        `{"a":{"type":"string","value":"hé😀\n"},"b":[{"type":"integer","value":"1"},{}]}`);
}

unittest
{
    // A table whose keys happen to be `type` and `value` holds tables.
    auto n = fromTaggedJson(`{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}`);
    assert(n.isTable && n["type"].isScalar && n["value"].isScalar);
    assert(toTaggedJson(n) ==
        `{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}`);
}

unittest
{
    auto s = scalar(ScalarType.string_, "a\"\\\b\f\n\r\t\x01\x1f\x7f é");
    assert(toTaggedJson(s) == "{\"type\":\"string\",\"value\":\"a\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\x7f é\"}");
    assert(toTaggedJson(table()) == "{}");
}

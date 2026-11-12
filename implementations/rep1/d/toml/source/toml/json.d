/**
 * The toml-test "tagged JSON" interchange format.
 *
 * Tables are JSON objects, arrays are JSON arrays and every scalar is an
 * object `{"type": T, "value": TEXT}` with both members strings.
 */
module toml.json;

import std.array : Appender, appender;
import toml.exception : TomlException;
import toml.utf8 : appendUtf8;
import toml.value;

/**
 * Renders a tree as compact tagged JSON with the keys of every object sorted
 * by code point.
 */
string toTaggedJson(Node root) @safe
{
    auto app = appender!(char[])();
    writeNode(app, root);
    return (() @trusted => cast(string) app.data)();
}

private void writeNode(ref Appender!(char[]) app, Node n) @safe
{
    final switch (n.kind)
    {
    case Kind.table:
        app ~= '{';
        bool first = true;
        foreach (k; n.sortedKeys)
        {
            if (!first)
                app ~= ',';
            first = false;
            writeString(app, k);
            app ~= ':';
            writeNode(app, n.members[k]);
        }
        app ~= '}';
        break;
    case Kind.array:
        app ~= '[';
        foreach (i, e; n.items)
        {
            if (i)
                app ~= ',';
            writeNode(app, e);
        }
        app ~= ']';
        break;
    case Kind.str:
    case Kind.integer:
    case Kind.floating:
    case Kind.boolean:
    case Kind.offsetDateTime:
    case Kind.localDateTime:
    case Kind.localDate:
    case Kind.localTime:
        app ~= `{"type":"`;
        app ~= typeName(n.kind);
        app ~= `","value":`;
        writeString(app, n.text);
        app ~= '}';
        break;
    }
}

private void writeString(ref Appender!(char[]) app, const(char)[] s) @safe
{
    static immutable hex = "0123456789abcdef";
    app ~= '"';
    size_t runStart = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\')
            continue;
        app ~= s[runStart .. i];
        runStart = i + 1;
        switch (c)
        {
        case '"':  app ~= `\"`; break;
        case '\\': app ~= `\\`; break;
        case '\b': app ~= `\b`; break;
        case '\f': app ~= `\f`; break;
        case '\n': app ~= `\n`; break;
        case '\r': app ~= `\r`; break;
        case '\t': app ~= `\t`; break;
        default:
            app ~= `\u00`;
            app ~= hex[c >> 4];
            app ~= hex[c & 15];
        }
    }
    app ~= s[runStart .. $];
    app ~= '"';
}

/**
 * Reads tagged JSON back into a tree.
 *
 * An object with exactly the two string members `type` and `value`, `type`
 * naming one of the eight scalar types, is a scalar; any other object is a table.
 * Throws: `TomlException` if the JSON is malformed.
 */
Node fromTaggedJson(const(char)[] json) @safe
{
    auto r = JsonReader(json);
    r.skipWs();
    auto n = r.readNode();
    r.skipWs();
    if (r.pos != json.length)
        r.fail("trailing data");
    return n;
}

private struct JsonReader
{
    const(char)[] src;
    size_t pos;

    noreturn fail(string msg) const @safe
    {
        throw new TomlException("invalid tagged JSON: " ~ msg, src, pos);
    }

    void skipWs() @safe pure nothrow @nogc
    {
        while (pos < src.length
               && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r'))
            ++pos;
    }

    void expect(char c) @safe
    {
        if (pos >= src.length || src[pos] != c)
            fail("expected '" ~ c ~ "'");
        ++pos;
    }

    Node readNode() @safe
    {
        if (pos >= src.length)
            fail("unexpected end");
        if (src[pos] == '{')
            return readObject();
        if (src[pos] == '[')
            return readArray();
        fail("expected an object or array");
    }

    Node readArray() @safe
    {
        ++pos;
        auto arr = Node.newArray();
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            ++pos;
            return arr;
        }
        for (;;)
        {
            skipWs();
            arr.items ~= readNode();
            skipWs();
            if (pos < src.length && src[pos] == ',')
                ++pos;
            else
            {
                expect(']');
                return arr;
            }
        }
    }

    Node readObject() @safe
    {
        ++pos;
        auto table = Node.newTable();
        string[string] strings; // string-valued members (only legal in scalar nodes)
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            ++pos;
            return table;
        }
        for (;;)
        {
            skipWs();
            auto key = readString();
            skipWs();
            expect(':');
            skipWs();
            if (pos < src.length && src[pos] == '"')
                strings[key] = readString();
            else
                table.members[key] = readNode();
            skipWs();
            if (pos < src.length && src[pos] == ',')
                ++pos;
            else
            {
                expect('}');
                break;
            }
        }
        Kind kind;
        if (strings.length == 2 && table.members.length == 0)
        {
            auto t = "type" in strings;
            auto v = "value" in strings;
            if (t && v && kindFromTypeName(*t, kind))
                return Node.scalar(kind, *v);
        }
        if (strings.length != 0)
            fail("unexpected string member");
        return table;
    }

    string readString() @safe
    {
        expect('"');
        char[] buf;
        for (;;)
        {
            immutable start = pos;
            while (pos < src.length && src[pos] != '"' && src[pos] != '\\')
                ++pos;
            buf ~= src[start .. pos];
            if (pos >= src.length)
                fail("unterminated string");
            if (src[pos] == '"')
            {
                ++pos;
                return buf.idup;
            }
            ++pos; // backslash
            if (pos >= src.length)
                fail("unterminated escape");
            immutable c = src[pos++];
            switch (c)
            {
            case '"': buf ~= '"'; break;
            case '\\': buf ~= '\\'; break;
            case '/': buf ~= '/'; break;
            case 'b': buf ~= '\b'; break;
            case 'f': buf ~= '\f'; break;
            case 'n': buf ~= '\n'; break;
            case 'r': buf ~= '\r'; break;
            case 't': buf ~= '\t'; break;
            case 'u':
                uint cp = readHex4();
                if (cp >= 0xD800 && cp <= 0xDBFF && pos + 1 < src.length
                    && src[pos] == '\\' && src[pos + 1] == 'u')
                {
                    pos += 2;
                    immutable lo = readHex4();
                    if (lo < 0xDC00 || lo > 0xDFFF)
                        fail("invalid surrogate pair");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                if (cp >= 0xD800 && cp <= 0xDFFF)
                    fail("lone surrogate");
                appendUtf8(buf, cp);
                break;
            default:
                fail("invalid escape");
            }
        }
    }

    uint readHex4() @safe
    {
        if (src.length - pos < 4)
            fail("truncated \\u escape");
        uint v = 0;
        foreach (_; 0 .. 4)
        {
            immutable c = src[pos++];
            uint d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else fail("invalid hex digit");
            v = v * 16 + d;
        }
        return v;
    }
}

unittest
{
    auto t = fromTaggedJson(` { "b" : { "type" : "integer", "value" : "5" },
        "a":[{"type":"string","value":"xé😀\n"}, []], "c":{} } `);
    assert(toTaggedJson(t) ==
        `{"a":[{"type":"string","value":"xé😀\n"},[]],"b":{"type":"integer","value":"5"},"c":{}}`);
    // A table whose keys are "type" and "value" is still a table.
    auto t2 = fromTaggedJson(`{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}`);
    assert(t2.isTable && t2["type"].asString == "a");
    assert(toTaggedJson(Node.fromString("\x01\x7f\"\\")) ==
        `{"type":"string","value":"\u0001` ~ "\x7f" ~ `\"\\"}`);
    assert(toTaggedJson(fromTaggedJson(`{}`)) == "{}");
}

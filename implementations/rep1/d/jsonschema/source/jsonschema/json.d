/**
 * A small JSON data model and a recursive-descent parser for RFC 8259.
 *
 * Numbers are kept exactly (see `jsonschema.number`); objects remember their
 * members in document order and also offer O(1) lookup by name.
 */
module jsonschema.json;

import jsonschema.number;

/// The JSON type of a `JsonValue`.
enum JsonType : ubyte
{
    null_,
    boolean,
    number,
    string,
    array,
    object,
}

/// Thrown for malformed JSON text.
class JsonException : Exception
{
    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__)
    {
        import std.conv : to;

        super(msg ~ " at offset " ~ offset.to!string, file, line);
    }
}

/// An immutable-by-convention JSON value.
final class JsonValue
{
    /// Which member below is meaningful.
    JsonType type;
    /// Payload of a boolean.
    bool boolean;
    /// Payload of a number.
    Number number;
    /// Payload of a string (UTF-8).
    string str;
    /// Elements of an array.
    JsonValue[] items;
    /// Member names of an object, in document order.
    string[] keys;
    /// Member values of an object, parallel to `keys`.
    JsonValue[] values;
    /// Name lookup table for objects.
    JsonValue[string] map;

    /// Creates `null`.
    static JsonValue makeNull()
    {
        return new JsonValue;
    }

    /// Creates a boolean.
    static JsonValue makeBool(bool b)
    {
        auto v = new JsonValue;
        v.type = JsonType.boolean;
        v.boolean = b;
        return v;
    }

    /// Creates a number.
    static JsonValue makeNumber(Number n)
    {
        auto v = new JsonValue;
        v.type = JsonType.number;
        v.number = n;
        return v;
    }

    /// Creates a string.
    static JsonValue makeString(string s)
    {
        auto v = new JsonValue;
        v.type = JsonType.string;
        v.str = s;
        return v;
    }

    /// Creates an array.
    static JsonValue makeArray(JsonValue[] items)
    {
        auto v = new JsonValue;
        v.type = JsonType.array;
        v.items = items;
        return v;
    }

    /// Creates an empty object; fill it with `put`.
    static JsonValue makeObject()
    {
        auto v = new JsonValue;
        v.type = JsonType.object;
        return v;
    }

    /// Adds a member to an object (the key must not be present yet).
    void put(string key, JsonValue value)
    {
        keys ~= key;
        values ~= value;
        map[key] = value;
    }

    /// True for objects.
    bool isObject() const
    {
        return type == JsonType.object;
    }

    /// True for arrays.
    bool isArray() const
    {
        return type == JsonType.array;
    }

    /// True for strings.
    bool isString() const
    {
        return type == JsonType.string;
    }

    /// True for numbers.
    bool isNumber() const
    {
        return type == JsonType.number;
    }

    /// Looks up an object member; returns `null` when absent or not an object.
    JsonValue get(string key)
    {
        if (type != JsonType.object)
            return null;
        if (auto p = key in map)
            return *p;
        return null;
    }
}

/// Parses `text` (a complete JSON document).
JsonValue parseJson(const(char)[] text)
{
    auto p = Parser(text);
    p.skipWs();
    auto v = p.parseValue();
    p.skipWs();
    if (p.pos != text.length)
        throw new JsonException("trailing characters", p.pos);
    return v;
}

private struct Parser
{
    const(char)[] src;
    size_t pos;

    this(const(char)[] s)
    {
        src = s;
    }

    void skipWs()
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                pos++;
            else
                break;
        }
    }

    JsonException fail(string msg)
    {
        return new JsonException(msg, pos);
    }

    JsonValue parseValue()
    {
        if (pos >= src.length)
            throw fail("unexpected end of input");
        switch (src[pos])
        {
        case '{':
            return parseObject();
        case '[':
            return parseArray();
        case '"':
            return JsonValue.makeString(parseString());
        case 't':
            expectWord("true");
            return JsonValue.makeBool(true);
        case 'f':
            expectWord("false");
            return JsonValue.makeBool(false);
        case 'n':
            expectWord("null");
            return JsonValue.makeNull();
        default:
            return parseNumber();
        }
    }

    void expectWord(string w)
    {
        if (pos + w.length > src.length || src[pos .. pos + w.length] != w)
            throw fail("invalid literal");
        pos += w.length;
    }

    JsonValue parseObject()
    {
        pos++; // {
        auto obj = JsonValue.makeObject();
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            pos++;
            return obj;
        }
        while (true)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                throw fail("expected object key");
            auto key = parseString();
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                throw fail("expected ':'");
            pos++;
            skipWs();
            auto val = parseValue();
            if (key in obj.map)
            {
                // Duplicate keys do not occur in valid inputs; last one wins.
                foreach (i, k; obj.keys)
                    if (k == key)
                        obj.values[i] = val;
                obj.map[key] = val;
            }
            else
                obj.put(key, val);
            skipWs();
            if (pos >= src.length)
                throw fail("unterminated object");
            if (src[pos] == ',')
            {
                pos++;
                continue;
            }
            if (src[pos] == '}')
            {
                pos++;
                return obj;
            }
            throw fail("expected ',' or '}'");
        }
    }

    JsonValue parseArray()
    {
        pos++; // [
        JsonValue[] items;
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            pos++;
            return JsonValue.makeArray(items);
        }
        while (true)
        {
            skipWs();
            items ~= parseValue();
            skipWs();
            if (pos >= src.length)
                throw fail("unterminated array");
            if (src[pos] == ',')
            {
                pos++;
                continue;
            }
            if (src[pos] == ']')
            {
                pos++;
                return JsonValue.makeArray(items);
            }
            throw fail("expected ',' or ']'");
        }
    }

    static int hexVal(char c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    uint parseHex4()
    {
        if (pos + 4 > src.length)
            throw fail("bad \\u escape");
        uint v = 0;
        foreach (i; 0 .. 4)
        {
            immutable h = hexVal(src[pos + i]);
            if (h < 0)
                throw fail("bad \\u escape");
            v = v * 16 + h;
        }
        pos += 4;
        return v;
    }

    string parseString()
    {
        pos++; // opening quote
        immutable start = pos;
        // Fast path: no escapes.
        while (pos < src.length && src[pos] != '"' && src[pos] != '\\')
        {
            if (cast(ubyte) src[pos] < 0x20)
                throw fail("control character in string");
            pos++;
        }
        if (pos >= src.length)
            throw fail("unterminated string");
        if (src[pos] == '"')
        {
            auto s = src[start .. pos].idup;
            pos++;
            return s;
        }
        char[] buf;
        buf ~= src[start .. pos];
        while (true)
        {
            if (pos >= src.length)
                throw fail("unterminated string");
            immutable c = src[pos];
            if (c == '"')
            {
                pos++;
                break;
            }
            if (cast(ubyte) c < 0x20)
                throw fail("control character in string");
            if (c != '\\')
            {
                buf ~= c;
                pos++;
                continue;
            }
            pos++;
            if (pos >= src.length)
                throw fail("unterminated escape");
            immutable e = src[pos++];
            switch (e)
            {
            case '"':
                buf ~= '"';
                break;
            case '\\':
                buf ~= '\\';
                break;
            case '/':
                buf ~= '/';
                break;
            case 'b':
                buf ~= '\b';
                break;
            case 'f':
                buf ~= '\f';
                break;
            case 'n':
                buf ~= '\n';
                break;
            case 'r':
                buf ~= '\r';
                break;
            case 't':
                buf ~= '\t';
                break;
            case 'u':
                {
                    uint cp = parseHex4();
                    if (cp >= 0xD800 && cp <= 0xDBFF && pos + 1 < src.length
                            && src[pos] == '\\' && src[pos + 1] == 'u')
                    {
                        immutable save = pos;
                        pos += 2;
                        immutable lo = parseHex4();
                        if (lo >= 0xDC00 && lo <= 0xDFFF)
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        else
                            pos = save;
                    }
                    appendUtf8(buf, cp);
                    break;
                }
            default:
                throw fail("invalid escape");
            }
        }
        return cast(string) buf;
    }

    JsonValue parseNumber()
    {
        immutable start = pos;
        bool neg = false;
        if (pos < src.length && src[pos] == '-')
        {
            neg = true;
            pos++;
        }
        char[] digits;
        immutable intStart = pos;
        while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
            pos++;
        if (pos == intStart)
            throw fail("invalid number");
        digits ~= src[intStart .. pos];
        long exp10 = 0;
        if (pos < src.length && src[pos] == '.')
        {
            pos++;
            immutable fs = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                pos++;
            if (pos == fs)
                throw fail("invalid number");
            digits ~= src[fs .. pos];
            exp10 -= cast(long)(pos - fs);
        }
        if (pos < src.length && (src[pos] == 'e' || src[pos] == 'E'))
        {
            pos++;
            bool eneg = false;
            if (pos < src.length && (src[pos] == '+' || src[pos] == '-'))
            {
                eneg = src[pos] == '-';
                pos++;
            }
            immutable es = pos;
            long e = 0;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
            {
                if (e < 100_000_000)
                    e = e * 10 + (src[pos] - '0');
                pos++;
            }
            if (pos == es)
                throw fail("invalid number");
            exp10 += eneg ? -e : e;
        }
        cast(void) start;
        return JsonValue.makeNumber(Number.fromDigits(neg, digits, exp10));
    }
}

/// Appends the UTF-8 encoding of code point `cp` (surrogates are encoded as-is).
void appendUtf8(ref char[] buf, uint cp)
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

/// JSON equality (RFC-style, with exact numbers): different types are never
/// equal, objects compare irrespective of member order.
bool jsonEqual(JsonValue a, JsonValue b)
{
    if (a is b)
        return true;
    if (a.type != b.type)
        return false;
    final switch (a.type)
    {
    case JsonType.null_:
        return true;
    case JsonType.boolean:
        return a.boolean == b.boolean;
    case JsonType.number:
        return a.number == b.number;
    case JsonType.string:
        return a.str == b.str;
    case JsonType.array:
        if (a.items.length != b.items.length)
            return false;
        foreach (i, x; a.items)
            if (!jsonEqual(x, b.items[i]))
                return false;
        return true;
    case JsonType.object:
        if (a.keys.length != b.keys.length)
            return false;
        foreach (i, k; a.keys)
        {
            auto p = k in b.map;
            if (p is null || !jsonEqual(a.values[i], *p))
                return false;
        }
        return true;
    }
}

/// A hash consistent with `jsonEqual`.
ulong jsonHash(JsonValue v)
{
    enum ulong mul = 0x9E3779B97F4A7C15UL;
    static ulong mix(ulong h)
    {
        h ^= h >> 33;
        h *= 0xff51afd7ed558ccdUL;
        h ^= h >> 33;
        h *= 0xc4ceb9fe1a85ec53UL;
        h ^= h >> 33;
        return h;
    }
    final switch (v.type)
    {
    case JsonType.null_:
        return 0x1234;
    case JsonType.boolean:
        return v.boolean ? 0x2345 : 0x3456;
    case JsonType.number:
        return mix(v.number.toHash() + 7);
    case JsonType.string:
        return mix(hashString(v.str) + 11);
    case JsonType.array:
        {
            ulong h = 0x4567;
            foreach (x; v.items)
                h = mix(h * mul + jsonHash(x));
            return h;
        }
    case JsonType.object:
        {
            ulong h = 0x5678;
            foreach (i, k; v.keys)
                h += mix(hashString(k) * mul + jsonHash(v.values[i]));
            return mix(h);
        }
    }
}

private ulong hashString(const(char)[] s)
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (c; s)
    {
        h ^= cast(ubyte) c;
        h *= 0x100000001b3UL;
    }
    return h;
}

unittest
{
    auto v = parseJson(` {"a": [1, 2.5e1, "xé💩"], "b": null, "c": true} `);
    assert(v.isObject && v.keys == ["a", "b", "c"]);
    auto a = v.get("a");
    assert(a.items.length == 3);
    assert(a.items[1].number == Number.fromLong(25));
    assert(a.items[2].str == "xé\U0001F4A9");
    assert(v.get("b").type == JsonType.null_);
    assert(v.get("zzz") is null);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!JsonException(parseJson("[1,]"));
    assertThrown!JsonException(parseJson("{\"a\" 1}"));
    assertThrown!JsonException(parseJson("01 2"));
    assertThrown!JsonException(parseJson("\"abc"));
}

unittest
{
    assert(jsonEqual(parseJson("1"), parseJson("1.00")));
    assert(jsonEqual(parseJson("100"), parseJson("1e2")));
    assert(!jsonEqual(parseJson("true"), parseJson("1")));
    assert(jsonEqual(parseJson(`{"a":1,"b":[2]}`), parseJson(`{"b":[2.0],"a":1.0}`)));
    assert(!jsonEqual(parseJson(`{"a":1}`), parseJson(`{"b":1}`)));
    assert(jsonHash(parseJson(`{"a":1,"b":[2]}`)) == jsonHash(parseJson(`{"b":[2.0],"a":1.0}`)));
    assert(jsonHash(parseJson("1")) == jsonHash(parseJson("1e0")));
}

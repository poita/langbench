/// A small recursive-descent JSON reader that preserves object member order.
module jinjalite.json;

import core.stdc.stdlib : strtod;
import std.array : appender;
import std.utf : encode;
import jinjalite.value;

/// Thrown when the JSON text is malformed.
class JsonException : Exception
{
    ///
    this(string message, size_t offset, string file = __FILE__, size_t line = __LINE__) pure @safe
    {
        import std.conv : text;
        super(text("invalid JSON at offset ", offset, ": ", message), file, line);
    }
}

/++
    Parse a JSON document into a `Value`.

    Numbers without a fraction or exponent become integers (falling back to
    floats when they do not fit in 64 bits); all others become floats. Objects
    become dicts that keep their member order.
+/
Value parseJson(string text)
{
    auto parser = JsonParser(text);
    parser.skipWs();
    auto result = parser.parseValue(0);
    parser.skipWs();
    if (parser.pos != text.length)
        throw new JsonException("trailing characters", parser.pos);
    return result;
}

private struct JsonParser
{
    string src;
    size_t pos;

    enum maxDepth = 512;

    void skipWs() pure nothrow @safe @nogc
    {
        while (pos < src.length)
        {
            const c = src[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                ++pos;
            else
                break;
        }
    }

    Value parseValue(size_t depth)
    {
        if (depth > maxDepth)
            throw new JsonException("nesting too deep", pos);
        if (pos >= src.length)
            throw new JsonException("unexpected end of input", pos);
        switch (src[pos])
        {
        case '{':
            return parseObject(depth);
        case '[':
            return parseArray(depth);
        case '"':
            return Value.text(parseString());
        case 't':
            expectWord("true");
            return Value.boolean(true);
        case 'f':
            expectWord("false");
            return Value.boolean(false);
        case 'n':
            expectWord("null");
            return Value.none;
        default:
            return parseNumber();
        }
    }

    void expectWord(string word)
    {
        if (pos + word.length > src.length || src[pos .. pos + word.length] != word)
            throw new JsonException("unexpected token", pos);
        pos += word.length;
    }

    Value parseObject(size_t depth)
    {
        ++pos; // '{'
        auto dict = new Dict;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            ++pos;
            return Value.dict(dict);
        }
        while (true)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                throw new JsonException("expected a string key", pos);
            auto key = parseString();
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                throw new JsonException("expected ':'", pos);
            ++pos;
            skipWs();
            dict.set(key, parseValue(depth + 1));
            skipWs();
            if (pos >= src.length)
                throw new JsonException("unterminated object", pos);
            if (src[pos] == ',')
            {
                ++pos;
                continue;
            }
            if (src[pos] == '}')
            {
                ++pos;
                return Value.dict(dict);
            }
            throw new JsonException("expected ',' or '}'", pos);
        }
    }

    Value parseArray(size_t depth)
    {
        ++pos; // '['
        Value[] items;
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            ++pos;
            return Value.list(items);
        }
        while (true)
        {
            skipWs();
            items ~= parseValue(depth + 1);
            skipWs();
            if (pos >= src.length)
                throw new JsonException("unterminated array", pos);
            if (src[pos] == ',')
            {
                ++pos;
                continue;
            }
            if (src[pos] == ']')
            {
                ++pos;
                return Value.list(items);
            }
            throw new JsonException("expected ',' or ']'", pos);
        }
    }

    string parseString()
    {
        ++pos; // opening quote
        const start = pos;
        // Fast path: no escapes, so the result is a slice of the input.
        while (pos < src.length && src[pos] != '"' && src[pos] != '\\')
            ++pos;
        if (pos >= src.length)
            throw new JsonException("unterminated string", pos);
        if (src[pos] == '"')
        {
            auto result = src[start .. pos];
            ++pos;
            return result;
        }
        auto buf = appender!(char[])();
        buf.put(src[start .. pos]);
        while (true)
        {
            if (pos >= src.length)
                throw new JsonException("unterminated string", pos);
            const c = src[pos];
            if (c == '"')
            {
                ++pos;
                return cast(string) buf.data;
            }
            if (c != '\\')
            {
                buf.put(c);
                ++pos;
                continue;
            }
            ++pos;
            if (pos >= src.length)
                throw new JsonException("unterminated escape", pos);
            const e = src[pos++];
            switch (e)
            {
            case '"':  buf.put('"'); break;
            case '\\': buf.put('\\'); break;
            case '/':  buf.put('/'); break;
            case 'b':  buf.put('\b'); break;
            case 'f':  buf.put('\f'); break;
            case 'n':  buf.put('\n'); break;
            case 'r':  buf.put('\r'); break;
            case 't':  buf.put('\t'); break;
            case 'u':
            {
                dchar cp = readHex4();
                if (cp >= 0xD800 && cp < 0xDC00 && pos + 1 < src.length && src[pos] == '\\' && src[pos + 1] == 'u')
                {
                    pos += 2;
                    const lo = readHex4();
                    if (lo >= 0xDC00 && lo < 0xE000)
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    else
                        throw new JsonException("invalid surrogate pair", pos);
                }
                if (cp >= 0xD800 && cp < 0xE000)
                    throw new JsonException("lone surrogate", pos);
                char[4] enc;
                const n = encode(enc, cp);
                buf.put(enc[0 .. n]);
                break;
            }
            default:
                throw new JsonException("invalid escape", pos);
            }
        }
    }

    dchar readHex4()
    {
        if (pos + 4 > src.length)
            throw new JsonException("truncated \\u escape", pos);
        uint v = 0;
        foreach (k; 0 .. 4)
        {
            const c = src[pos + k];
            uint digit;
            if (c >= '0' && c <= '9') digit = c - '0';
            else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
            else throw new JsonException("bad hex digit", pos + k);
            v = v * 16 + digit;
        }
        pos += 4;
        return cast(dchar) v;
    }

    Value parseNumber()
    {
        const start = pos;
        bool negative = false;
        if (pos < src.length && src[pos] == '-')
        {
            negative = true;
            ++pos;
        }
        const digitsStart = pos;
        while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
            ++pos;
        if (pos == digitsStart)
            throw new JsonException("unexpected character", start);
        bool isFloat = false;
        if (pos < src.length && src[pos] == '.')
        {
            isFloat = true;
            ++pos;
            const fracStart = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                ++pos;
            if (pos == fracStart)
                throw new JsonException("digits expected after '.'", pos);
        }
        if (pos < src.length && (src[pos] == 'e' || src[pos] == 'E'))
        {
            isFloat = true;
            ++pos;
            if (pos < src.length && (src[pos] == '+' || src[pos] == '-'))
                ++pos;
            const expStart = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                ++pos;
            if (pos == expStart)
                throw new JsonException("digits expected in exponent", pos);
        }
        const literal = src[start .. pos];
        if (!isFloat)
        {
            ulong magnitude = 0;
            bool overflow = false;
            foreach (c; src[digitsStart .. pos])
            {
                const digit = c - '0';
                if (magnitude > (ulong.max - digit) / 10)
                {
                    overflow = true;
                    break;
                }
                magnitude = magnitude * 10 + digit;
            }
            const limit = negative ? cast(ulong) long.max + 1 : cast(ulong) long.max;
            if (!overflow && magnitude <= limit)
                return Value.integer(negative ? cast(long)(-magnitude) : cast(long) magnitude);
        }
        // strtod needs a NUL-terminated copy.
        auto z = literal ~ '\0';
        return Value.floating(strtod(z.ptr, null));
    }
}

unittest
{
    auto v = parseJson(`{"b": 1, "a": [1.5, -2, 1e2, "xé\n"], "c": {"t": true, "f": false, "n": null}}`);
    auto d = v.asDict;
    assert(d.keys == ["b", "a", "c"]);
    assert(d.find("b").kind == Kind.integer);
    auto a = d.find("a").items;
    assert(a[0].kind == Kind.floating && a[0].d == 1.5);
    assert(a[1].kind == Kind.integer && a[1].i == -2);
    assert(a[2].kind == Kind.floating && a[2].d == 100.0);
    assert(a[3].s == "xé\n");
    assert(d.find("c").asDict.find("n").kind == Kind.none);
}

unittest
{
    assert(parseJson("-0").i == 0);
    assert(parseJson("9223372036854775807").i == long.max);
    assert(parseJson("-9223372036854775808").i == long.min);
    assert(parseJson("9223372036854775808").kind == Kind.floating);
    assert(parseJson(`"😀"`).s == "\U0001F600");
    assert(parseJson("  [ ]  ").items.length == 0);
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!JsonException(parseJson("{"));
    assertThrown!JsonException(parseJson("[1,]"));
    assertThrown!JsonException(parseJson(`{"a" 1}`));
    assertThrown!JsonException(parseJson("1 2"));
    assertThrown!JsonException(parseJson(`"abc`));
    assertThrown!JsonException(parseJson("01x"));
}

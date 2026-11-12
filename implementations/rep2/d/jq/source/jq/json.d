/**
 * Hand-written JSON parser and compact serializer.
 *
 * Parsing is a single recursive-descent pass over the text; strings without
 * escapes are slices of the source text (no copy). Numbers are the IEEE-754
 * double nearest to their decimal value. Serialization follows jq's `-c`
 * output conventions (see $(D writeJson)).
 */
module jq.json;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.array : appender, Appender;
import std.range.primitives : put;

import jq.errors : JsonException;
import jq.value;

/// Parses exactly one JSON document (surrounding whitespace allowed).
Value parseJson(string text, size_t maxDepth = 1000)
{
    auto p = JsonParser(text, 0, maxDepth);
    p.skipWs();
    auto v = p.parseValue(0);
    p.skipWs();
    if (p.pos != text.length)
        throw new JsonException("trailing characters after JSON value");
    return v;
}

private struct JsonParser
{
    string src;
    size_t pos;
    size_t maxDepth;

    void skipWs() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\n' || c == '\t' || c == '\r')
                pos++;
            else
                break;
        }
    }

    Value parseValue(size_t depth)
    {
        if (pos >= src.length)
            throw new JsonException("unexpected end of input");
        switch (src[pos])
        {
        case '{':
            return parseObject(depth);
        case '[':
            return parseArray(depth);
        case '"':
            return Value.fromString(parseString());
        case 't':
            expectWord("true");
            return Value.fromBool(true);
        case 'f':
            expectWord("false");
            return Value.fromBool(false);
        case 'n':
            expectWord("null");
            return Value.nil;
        default:
            return parseNumber();
        }
    }

    void expectWord(string w)
    {
        if (pos + w.length > src.length || src[pos .. pos + w.length] != w)
            throw new JsonException("invalid literal");
        pos += w.length;
    }

    Value parseObject(size_t depth)
    {
        if (depth >= maxDepth)
            throw new JsonException("nesting too deep");
        pos++; // {
        auto o = new JObject;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            pos++;
            return Value.fromObject(o);
        }
        while (true)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                throw new JsonException("expected object key");
            auto key = parseString();
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                throw new JsonException("expected ':'");
            pos++;
            skipWs();
            o.set(key, parseValue(depth + 1));
            skipWs();
            if (pos >= src.length)
                throw new JsonException("unterminated object");
            if (src[pos] == ',')
            {
                pos++;
                continue;
            }
            if (src[pos] == '}')
            {
                pos++;
                return Value.fromObject(o);
            }
            throw new JsonException("expected ',' or '}'");
        }
    }

    Value parseArray(size_t depth)
    {
        if (depth >= maxDepth)
            throw new JsonException("nesting too deep");
        pos++; // [
        auto items = appender!(Value[]);
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            pos++;
            return Value.fromArray(null);
        }
        while (true)
        {
            skipWs();
            items.put(parseValue(depth + 1));
            skipWs();
            if (pos >= src.length)
                throw new JsonException("unterminated array");
            if (src[pos] == ',')
            {
                pos++;
                continue;
            }
            if (src[pos] == ']')
            {
                pos++;
                return Value.fromArray(items.data);
            }
            throw new JsonException("expected ',' or ']'");
        }
    }

    string parseString()
    {
        pos++; // opening quote
        immutable start = pos;
        bool escaped = false;
        while (true)
        {
            if (pos >= src.length)
                throw new JsonException("unterminated string");
            immutable c = src[pos];
            if (c == '"')
                break;
            if (c == '\\')
            {
                escaped = true;
                pos += 2;
                continue;
            }
            pos++;
        }
        auto body_ = src[start .. pos];
        pos++; // closing quote
        return escaped ? unescapeJsonString(body_) : body_;
    }

    Value parseNumber()
    {
        immutable start = pos;
        if (pos < src.length && src[pos] == '-')
            pos++;
        immutable digitsStart = pos;
        while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
            pos++;
        immutable intDigits = pos - digitsStart;
        if (intDigits == 0)
            throw new JsonException("invalid number");
        bool simple = true;
        if (pos < src.length && src[pos] == '.')
        {
            simple = false;
            pos++;
            immutable fs = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                pos++;
            if (pos == fs)
                throw new JsonException("invalid number");
        }
        if (pos < src.length && (src[pos] == 'e' || src[pos] == 'E'))
        {
            simple = false;
            pos++;
            if (pos < src.length && (src[pos] == '+' || src[pos] == '-'))
                pos++;
            immutable es = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                pos++;
            if (pos == es)
                throw new JsonException("invalid number");
        }
        if (simple && intDigits <= 15)
        {
            long n = 0;
            foreach (c; src[digitsStart .. pos])
                n = n * 10 + (c - '0');
            return Value.fromNumber(src[start] == '-' ? -cast(double) n : cast(double) n);
        }
        return Value.fromNumber(strtodSpan(src[start .. pos]));
    }
}

/// Converts the text of an already validated number to a double (correctly rounded).
private double strtodSpan(const(char)[] s) @trusted
{
    char[64] small = void;
    char[] buf = s.length < small.length ? small[] : new char[s.length + 1];
    buf[0 .. s.length] = s[];
    buf[s.length] = 0;
    return strtod(buf.ptr, null);
}

/**
 * Parses `s` as a complete JSON number (no surrounding whitespace, no leading
 * `+`, no leading zeros). Returns false when `s` is not one.
 */
bool tryParseNumber(const(char)[] s, out double result)
{
    size_t i = 0;
    if (i < s.length && s[i] == '-')
        i++;
    if (i >= s.length)
        return false;
    if (s[i] == '0')
        i++;
    else if (s[i] >= '1' && s[i] <= '9')
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
    else
        return false;
    if (i < s.length && s[i] == '.')
    {
        i++;
        immutable fs = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        if (i == fs)
            return false;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-'))
            i++;
        immutable es = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        if (i == es)
            return false;
    }
    if (i != s.length)
        return false;
    result = strtodSpan(s);
    return true;
}

private int hexVal(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private dchar readHex4(string s, size_t i)
{
    if (i + 4 > s.length)
        throw new JsonException("truncated \\u escape");
    uint v = 0;
    foreach (k; 0 .. 4)
    {
        immutable h = hexVal(s[i + k]);
        if (h < 0)
            throw new JsonException("invalid \\u escape");
        v = v * 16 + h;
    }
    return cast(dchar) v;
}

private void putCodePoint(ref Appender!(char[]) a, uint c)
{
    if (c < 0x80)
        a.put(cast(char) c);
    else if (c < 0x800)
    {
        a.put(cast(char)(0xC0 | (c >> 6)));
        a.put(cast(char)(0x80 | (c & 0x3F)));
    }
    else if (c < 0x10000)
    {
        a.put(cast(char)(0xE0 | (c >> 12)));
        a.put(cast(char)(0x80 | ((c >> 6) & 0x3F)));
        a.put(cast(char)(0x80 | (c & 0x3F)));
    }
    else
    {
        a.put(cast(char)(0xF0 | (c >> 18)));
        a.put(cast(char)(0x80 | ((c >> 12) & 0x3F)));
        a.put(cast(char)(0x80 | ((c >> 6) & 0x3F)));
        a.put(cast(char)(0x80 | (c & 0x3F)));
    }
}

/// Decodes the JSON escapes of a string body (the text between the quotes).
string unescapeJsonString(string s)
{
    auto a = appender!(char[]);
    a.reserve(s.length);
    size_t i = 0;
    while (i < s.length)
    {
        immutable c = s[i];
        if (c != '\\')
        {
            a.put(c);
            i++;
            continue;
        }
        if (i + 1 >= s.length)
            throw new JsonException("truncated escape");
        immutable e = s[i + 1];
        i += 2;
        switch (e)
        {
        case '"':
            a.put('"');
            break;
        case '\\':
            a.put('\\');
            break;
        case '/':
            a.put('/');
            break;
        case 'b':
            a.put('\b');
            break;
        case 'f':
            a.put('\f');
            break;
        case 'n':
            a.put('\n');
            break;
        case 'r':
            a.put('\r');
            break;
        case 't':
            a.put('\t');
            break;
        case 'u':
            uint cp = readHex4(s, i);
            i += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF)
            {
                if (i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u')
                {
                    immutable lo = readHex4(s, i + 2);
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                    {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                    else
                        cp = 0xFFFD;
                }
                else
                    cp = 0xFFFD;
            }
            else if (cp >= 0xDC00 && cp <= 0xDFFF)
                cp = 0xFFFD;
            putCodePoint(a, cp);
            break;
        default:
            throw new JsonException("invalid escape");
        }
    }
    return cast(string) a.data;
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/**
 * Writes `v` as compact JSON to the output range `sink` (anything accepting
 * `put(const(char)[])` / `put(char)`).
 *
 * Strings escape `"`, `\`, and control characters (`\b \f \n \r \t`, others as
 * lowercase `\u00xx`), plus U+007F as `\u007f`; all other code points are
 * emitted raw. Objects print in insertion order.
 */
void writeJson(Sink)(ref Sink sink, Value v)
{
    final switch (v.kind)
    {
    case Kind.null_:
        put(sink, "null");
        break;
    case Kind.false_:
        put(sink, "false");
        break;
    case Kind.true_:
        put(sink, "true");
        break;
    case Kind.number:
        char[40] buf = void;
        put(sink, formatNumber(v.num, buf));
        break;
    case Kind.string:
        writeJsonString(sink, v.str);
        break;
    case Kind.array:
        put(sink, '[');
        bool first = true;
        foreach (e; v.arr)
        {
            if (!first)
                put(sink, ',');
            first = false;
            writeJson(sink, e);
        }
        put(sink, ']');
        break;
    case Kind.object:
        put(sink, '{');
        auto o = v.obj;
        foreach (i, k; o.keys)
        {
            if (i)
                put(sink, ',');
            writeJsonString(sink, k);
            put(sink, ':');
            writeJson(sink, o.values[i]);
        }
        put(sink, '}');
        break;
    }
}

/// Serializes `v` to a compact JSON string.
string toJson(Value v)
{
    auto a = appender!(char[]);
    writeJson(a, v);
    return cast(string) a.data;
}

/// Writes `s` as a quoted, escaped JSON string.
void writeJsonString(Sink)(ref Sink sink, string s)
{
    static immutable hexDigits = "0123456789abcdef";
    put(sink, '"');
    size_t runStart = 0;
    foreach (i, c; s)
    {
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7f)
            continue;
        if (i > runStart)
            put(sink, s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"':
            put(sink, `\"`);
            break;
        case '\\':
            put(sink, `\\`);
            break;
        case '\b':
            put(sink, `\b`);
            break;
        case '\f':
            put(sink, `\f`);
            break;
        case '\n':
            put(sink, `\n`);
            break;
        case '\r':
            put(sink, `\r`);
            break;
        case '\t':
            put(sink, `\t`);
            break;
        default:
            char[6] e = ['\\', 'u', '0', '0', hexDigits[c >> 4], hexDigits[c & 15]];
            put(sink, e[]);
        }
    }
    if (s.length > runStart)
        put(sink, s[runStart .. $]);
    put(sink, '"');
}

/**
 * Formats a double into `buf` and returns the used slice.
 *
 * Integral values print as integers; others print in the shortest `%g` form
 * (15 to 17 significant digits) that round-trips.
 */
char[] formatNumber(double d, return ref char[40] buf) @trusted
{
    import core.stdc.math : floor, fabs;

    if (d != d)
    {
        buf[0 .. 4] = "null";
        return buf[0 .. 4];
    }
    if (d == floor(d) && fabs(d) < 1e17)
    {
        long l = cast(long) d;
        if (l == 0)
        {
            if (1.0 / d < 0)
            {
                buf[0 .. 2] = "-0";
                return buf[0 .. 2];
            }
            buf[0] = '0';
            return buf[0 .. 1];
        }
        immutable neg = l < 0;
        ulong u = neg ? -cast(ulong) l : cast(ulong) l;
        size_t i = buf.length;
        while (u)
        {
            buf[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        if (neg)
            buf[--i] = '-';
        return buf[i .. $];
    }
    if (d > double.max || d < -double.max)
    {
        auto s = d > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308";
        buf[0 .. s.length] = s;
        return buf[0 .. s.length];
    }
    int n;
    foreach (prec; 15 .. 18)
    {
        n = snprintf(buf.ptr, buf.length, "%.*g", prec, d);
        if (strtod(buf.ptr, null) == d)
            break;
    }
    return buf[0 .. n];
}

unittest
{
    assert(toJson(parseJson(`  [1, 2.5, "a", null, true, false, {"b":1,"a":[]}]  `)) ==
            `[1,2.5,"a",null,true,false,{"b":1,"a":[]}]`);
    assert(toJson(parseJson(`"😀 é \/ \b\f\n\r\t \u0001 \u007f \"\\"`)) ==
            "\"\U0001F600 é / \\b\\f\\n\\r\\t \\u0001 \\u007f \\\"\\\\\"");
    assert(toJson(parseJson(`{"z":1,"a":2,"m":3}`)) == `{"z":1,"a":2,"m":3}`);
}

unittest
{
    foreach (s; ["0", "3", "-12", "1000000000000", "1.5", "0.125", "3086419725308.5", "-0.001",
            "9007199254740991", "123456.789"])
        assert(toJson(parseJson(s)) == s, s);
    assert(toJson(parseJson("1e2")) == "100");
    assert(toJson(parseJson("2.50")) == "2.5");
    assert(toJson(parseJson("0.1")) == "0.1");
    assert(toJson(Value.fromNumber(0.1 + 0.2)) == "0.30000000000000004");
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!JsonException(parseJson("[1,"));
    assertThrown!JsonException(parseJson("{\"a\" 1}"));
    assertThrown!JsonException(parseJson("tru"));
    assertThrown!JsonException(parseJson("1 2"));
    assertThrown!JsonException(parseJson("\"abc"));
    assertThrown!JsonException(parseJson("-"));
    double d;
    assert(tryParseNumber("-2.5", d) && d == -2.5);
    assert(!tryParseNumber("", d));
    assert(!tryParseNumber(" 1", d));
    assert(!tryParseNumber("007", d));
    assert(!tryParseNumber("1x", d));
}

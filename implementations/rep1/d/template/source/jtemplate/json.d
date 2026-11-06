/// A small JSON reader that produces template [Value]s.
///
/// Unlike `std.json`, it preserves the order of object members, maps numbers
/// without a fraction or exponent to integers, and reuses slices of the input
/// for strings that contain no escapes.
module jtemplate.json;

import core.stdc.stdlib : strtod;

import jtemplate.errors;
import jtemplate.value;

/// Parse a complete JSON document. Throws a syntax [TemplateError] if the
/// text is not valid JSON.
Value parseJson(string text)
{
    auto p = JsonReader(text);
    p.skipSpace();
    auto v = p.value();
    p.skipSpace();
    if (p.pos != text.length)
        throw syntaxError("trailing characters after JSON value");
    return v;
}

private struct JsonReader
{
    string src;
    size_t pos;
    uint depth;

    this(string s) { src = s; }

    void skipSpace() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++pos;
            else break;
        }
    }

    TemplateError fail(string msg) @safe pure nothrow { return syntaxError("json: " ~ msg); }

    Value value()
    {
        if (pos >= src.length)
            throw fail("unexpected end");
        if (++depth > 512)
            throw fail("nesting too deep");
        scope (exit) --depth;
        switch (src[pos])
        {
            case '{': return object();
            case '[': return array();
            case '"': return Value.fromString(string_());
            case 't': literal("true"); return Value.fromBool(true);
            case 'f': literal("false"); return Value.fromBool(false);
            case 'n': literal("null"); return Value.nil;
            default:  return number();
        }
    }

    void literal(string word)
    {
        if (pos + word.length > src.length || src[pos .. pos + word.length] != word)
            throw fail("bad literal");
        pos += word.length;
    }

    Value object()
    {
        ++pos; // {
        auto d = new DictObj;
        skipSpace();
        if (pos < src.length && src[pos] == '}')
        {
            ++pos;
            return Value.fromDict(d);
        }
        for (;;)
        {
            skipSpace();
            if (pos >= src.length || src[pos] != '"')
                throw fail("expected object key");
            auto key = string_();
            skipSpace();
            if (pos >= src.length || src[pos] != ':')
                throw fail("expected ':'");
            ++pos;
            skipSpace();
            d.put(key, value());
            skipSpace();
            if (pos >= src.length)
                throw fail("unterminated object");
            immutable c = src[pos++];
            if (c == '}') break;
            if (c != ',') throw fail("expected ',' or '}'");
        }
        return Value.fromDict(d);
    }

    Value array()
    {
        ++pos; // [
        Value[] items;
        skipSpace();
        if (pos < src.length && src[pos] == ']')
        {
            ++pos;
            return Value.fromList(items);
        }
        for (;;)
        {
            skipSpace();
            items ~= value();
            skipSpace();
            if (pos >= src.length)
                throw fail("unterminated array");
            immutable c = src[pos++];
            if (c == ']') break;
            if (c != ',') throw fail("expected ',' or ']'");
        }
        return Value.fromList(items);
    }

    Value number()
    {
        immutable start = pos;
        if (pos < src.length && src[pos] == '-') ++pos;
        immutable digitsStart = pos;
        while (pos < src.length && src[pos] >= '0' && src[pos] <= '9') ++pos;
        if (pos == digitsStart)
            throw fail("bad number");
        bool isFloat = false;
        if (pos < src.length && src[pos] == '.')
        {
            isFloat = true;
            ++pos;
            immutable f = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9') ++pos;
            if (pos == f) throw fail("bad number");
        }
        if (pos < src.length && (src[pos] == 'e' || src[pos] == 'E'))
        {
            isFloat = true;
            ++pos;
            if (pos < src.length && (src[pos] == '+' || src[pos] == '-')) ++pos;
            immutable f = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9') ++pos;
            if (pos == f) throw fail("bad number");
        }
        auto text = src[start .. pos];
        if (!isFloat)
        {
            // accumulate as a negative number so long.min parses
            bool neg = text[0] == '-';
            ulong acc = 0;
            bool overflow = false;
            foreach (ch; (neg ? text[1 .. $] : text))
            {
                immutable dgt = ch - '0';
                if (acc > (ulong.max - dgt) / 10) { overflow = true; break; }
                acc = acc * 10 + dgt;
            }
            if (!overflow)
            {
                if (!neg && acc <= long.max)
                    return Value.fromInt(cast(long) acc);
                if (neg && acc <= cast(ulong) long.max + 1)
                    return Value.fromInt(cast(long)(0UL - acc));
            }
        }
        return Value.fromFloat(toDouble(text));
    }

    string string_()
    {
        ++pos; // opening quote
        immutable start = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                auto s = src[start .. pos];
                ++pos;
                return s;
            }
            if (c == '\\')
                return escapedString(start);
            ++pos;
        }
        throw fail("unterminated string");
    }

    string escapedString(size_t start)
    {
        import std.utf : encode;
        char[] buf;
        buf ~= src[start .. pos];
        while (pos < src.length)
        {
            immutable c = src[pos++];
            if (c == '"')
                return cast(string) buf;
            if (c != '\\')
            {
                buf ~= c;
                continue;
            }
            if (pos >= src.length) break;
            immutable e = src[pos++];
            switch (e)
            {
                case '"':  buf ~= '"'; break;
                case '\\': buf ~= '\\'; break;
                case '/':  buf ~= '/'; break;
                case 'b':  buf ~= '\b'; break;
                case 'f':  buf ~= '\f'; break;
                case 'n':  buf ~= '\n'; break;
                case 'r':  buf ~= '\r'; break;
                case 't':  buf ~= '\t'; break;
                case 'u':
                {
                    dchar cp = hex4();
                    if (cp >= 0xD800 && cp < 0xDC00 && pos + 1 < src.length
                        && src[pos] == '\\' && src[pos + 1] == 'u')
                    {
                        pos += 2;
                        immutable lo = hex4();
                        if (lo >= 0xDC00 && lo < 0xE000)
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        else
                            throw fail("bad surrogate pair");
                    }
                    if (cp >= 0xD800 && cp < 0xE000)
                        throw fail("lone surrogate");
                    char[4] tmp;
                    immutable n = encode(tmp, cp);
                    buf ~= tmp[0 .. n];
                    break;
                }
                default: throw fail("bad escape");
            }
        }
        throw fail("unterminated string");
    }

    uint hex4()
    {
        if (pos + 4 > src.length)
            throw fail("bad \\u escape");
        uint v = 0;
        foreach (ch; src[pos .. pos + 4])
        {
            v <<= 4;
            if (ch >= '0' && ch <= '9') v |= ch - '0';
            else if (ch >= 'a' && ch <= 'f') v |= ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') v |= ch - 'A' + 10;
            else throw fail("bad \\u escape");
        }
        pos += 4;
        return v;
    }
}

private double toDouble(const(char)[] text) @trusted
{
    char[64] tmp = void;
    if (text.length < tmp.length)
    {
        tmp[0 .. text.length] = text[];
        tmp[text.length] = '\0';
        return strtod(tmp.ptr, null);
    }
    import std.conv : to;
    return to!double(text);
}

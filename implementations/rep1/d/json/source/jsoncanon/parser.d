/**
 * Strict recursive-descent JSON parser (RFC 8259).
 *
 * The whole input is first checked as UTF-8; it is then parsed in a single
 * forward pass with no backtracking. The first error aborts the parse with a
 * $(LREF JsonException). Nesting is limited to $(LREF maxDepth) levels.
 */
module jsoncanon.parser;

import std.array : Appender;

import jsoncanon.utf8;
import jsoncanon.value;

/// Maximum supported nesting depth of arrays and objects.
enum maxDepth = 512;

/// Thrown when a document is not valid JSON under the rules of this library.
class JsonException : Exception
{
    /// Byte offset of the error in the input (best effort).
    size_t offset;

    ///
    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/**
 * Parses a complete document.
 *
 * The whole of `input` is the document: surrounding whitespace is allowed,
 * anything else after the value is an error. The input is copied, so the
 * returned tree does not alias it.
 *
 * Throws: $(LREF JsonException) if the input is invalid.
 */
JsonValue parse(scope const(ubyte)[] input) @trusted
{
    if (!isValidUtf8(input))
        throw new JsonException("invalid UTF-8", 0);
    // Decoded strings without escapes are slices of this copy.
    immutable(ubyte)[] copy = input.idup;
    auto p = Parser(copy);
    return p.parseDocument();
}

/// ditto
JsonValue parse(scope const(char)[] input) @safe
{
    return parse(cast(const(ubyte)[]) input);
}

/// Parses `input`; returns `false` instead of throwing when it is invalid.
bool tryParse(scope const(ubyte)[] input, out JsonValue result) @safe
{
    try
    {
        result = parse(input);
        return true;
    }
    catch (JsonException)
        return false;
}

private struct Parser
{
    immutable(ubyte)[] src;
    size_t pos;
    int depth;

    // Scratch stacks: children are pushed here and copied out when their
    // container closes, so no per-container growth buffers are needed.
    JsonValue[] itemStack;
    JsonMember[] memberStack;
    Appender!(char[]) strBuf;

    this(immutable(ubyte)[] src) @safe
    {
        this.src = src;
    }

    noreturn fail(string msg) const @safe pure
    {
        throw new JsonException(msg, pos);
    }

    void skipWs() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t')
                ++pos;
            else
                break;
        }
    }

    JsonValue parseDocument() @safe
    {
        skipWs();
        auto v = parseValue();
        skipWs();
        if (pos != src.length)
            fail("unexpected data after value");
        return v;
    }

    JsonValue parseValue() @safe
    {
        if (pos >= src.length)
            fail("unexpected end of input");
        switch (src[pos])
        {
        case '{':
            return parseObject();
        case '[':
            return parseArray();
        case '"':
            return JsonValue.makeString(parseString());
        case '-':
        case '0': .. case '9':
            return parseNumber();
        case 't':
            expectLiteral("true");
            return JsonValue.makeBool(true);
        case 'f':
            expectLiteral("false");
            return JsonValue.makeBool(false);
        case 'n':
            expectLiteral("null");
            return JsonValue.makeNull();
        default:
            fail("unexpected character");
        }
    }

    void expectLiteral(string lit) @safe
    {
        if (src.length - pos < lit.length || cast(const(char)[]) src[pos .. pos + lit.length] != lit)
            fail("invalid literal");
        pos += lit.length;
    }

    JsonValue parseArray() @trusted
    {
        if (++depth > maxDepth)
            fail("nesting too deep");
        ++pos; // '['
        immutable base = itemStack.length;
        skipWs();
        if (pos < src.length && src[pos] == ']')
            ++pos;
        else
        {
            while (true)
            {
                skipWs();
                auto v = parseValue();
                itemStack ~= v;
                skipWs();
                if (pos >= src.length)
                    fail("unterminated array");
                immutable c = src[pos++];
                if (c == ',')
                    continue;
                if (c == ']')
                    break;
                --pos;
                fail("expected ',' or ']'");
            }
        }
        --depth;
        auto items = itemStack[base .. $].dup;
        itemStack.length = base;
        itemStack.assumeSafeAppend();
        return JsonValue.makeArray(items);
    }

    JsonValue parseObject() @trusted
    {
        if (++depth > maxDepth)
            fail("nesting too deep");
        ++pos; // '{'
        immutable base = memberStack.length;
        skipWs();
        if (pos < src.length && src[pos] == '}')
            ++pos;
        else
        {
            while (true)
            {
                skipWs();
                if (pos >= src.length || src[pos] != '"')
                    fail("expected object key");
                string key = parseString();
                skipWs();
                if (pos >= src.length || src[pos] != ':')
                    fail("expected ':'");
                ++pos;
                skipWs();
                auto v = parseValue();
                memberStack ~= JsonMember(key, v);
                skipWs();
                if (pos >= src.length)
                    fail("unterminated object");
                immutable c = src[pos++];
                if (c == ',')
                    continue;
                if (c == '}')
                    break;
                --pos;
                fail("expected ',' or '}'");
            }
        }
        --depth;
        auto members = memberStack[base .. $].dup;
        memberStack.length = base;
        memberStack.assumeSafeAppend();
        return JsonValue.makeObject(members);
    }

    static int hexValue(ubyte c) @safe pure nothrow @nogc
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    /// Reads four hex digits at `pos` (just after `\u`).
    uint parseHex4() @safe
    {
        if (src.length - pos < 4)
            fail("truncated \\u escape");
        uint v = 0;
        foreach (i; 0 .. 4)
        {
            immutable h = hexValue(src[pos + i]);
            if (h < 0)
                fail("bad hex digit in \\u escape");
            v = (v << 4) | h;
        }
        pos += 4;
        return v;
    }

    /// Parses a string starting at the opening quote; returns it decoded.
    string parseString() @trusted
    {
        ++pos; // opening quote
        immutable start = pos;
        // Fast path: no escapes, so the result is a slice of the input.
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                auto s = cast(string) src[start .. pos];
                ++pos;
                return s;
            }
            if (c == '\\' || c < 0x20)
                break;
            ++pos;
        }
        if (pos >= src.length)
            fail("unterminated string");

        strBuf.clear();
        strBuf.put(cast(const(char)[]) src[start .. pos]);
        while (true)
        {
            if (pos >= src.length)
                fail("unterminated string");
            immutable c = src[pos];
            if (c == '"')
            {
                ++pos;
                return strBuf.data.idup;
            }
            if (c < 0x20)
                fail("control character in string");
            if (c != '\\')
            {
                // Copy a run of ordinary bytes.
                immutable runStart = pos;
                while (pos < src.length && src[pos] != '"' && src[pos] != '\\' && src[pos] >= 0x20)
                    ++pos;
                strBuf.put(cast(const(char)[]) src[runStart .. pos]);
                continue;
            }
            ++pos; // backslash
            if (pos >= src.length)
                fail("unterminated string");
            immutable e = src[pos++];
            switch (e)
            {
            case '"':
                strBuf.put('"');
                break;
            case '\\':
                strBuf.put('\\');
                break;
            case '/':
                strBuf.put('/');
                break;
            case 'b':
                strBuf.put('\b');
                break;
            case 'f':
                strBuf.put('\f');
                break;
            case 'n':
                strBuf.put('\n');
                break;
            case 'r':
                strBuf.put('\r');
                break;
            case 't':
                strBuf.put('\t');
                break;
            case 'u':
                {
                    uint cp = parseHex4();
                    if (cp >= 0xD800 && cp <= 0xDBFF)
                    {
                        if (src.length - pos < 2 || src[pos] != '\\' || src[pos + 1] != 'u')
                            fail("unpaired high surrogate");
                        pos += 2;
                        immutable lo = parseHex4();
                        if (lo < 0xDC00 || lo > 0xDFFF)
                            fail("high surrogate not followed by low surrogate");
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    else if (cp >= 0xDC00 && cp <= 0xDFFF)
                        fail("unpaired low surrogate");
                    encodeUtf8(strBuf, cp);
                    break;
                }
            default:
                --pos;
                fail("invalid escape");
            }
        }
    }

    static bool isDigit(ubyte c) @safe pure nothrow @nogc
    {
        return c >= '0' && c <= '9';
    }

    bool atDigit() const @safe pure nothrow @nogc
    {
        return pos < src.length && isDigit(src[pos]);
    }

    void skipDigits() @safe pure nothrow @nogc
    {
        while (pos < src.length && isDigit(src[pos]))
            ++pos;
    }

    /**
     * Parses a number and returns it with its canonical text: the lexeme as
     * written, except that an exponent is normalised (lowercase `e`, no `+`,
     * no leading zeros, no sign on zero).
     */
    JsonValue parseNumber() @trusted
    {
        immutable start = pos;
        if (src[pos] == '-')
            ++pos;
        if (pos >= src.length)
            fail("bad number");
        if (src[pos] == '0')
            ++pos;
        else if (src[pos] >= '1' && src[pos] <= '9')
            skipDigits();
        else
            fail("bad number");
        if (pos < src.length && src[pos] == '.')
        {
            ++pos;
            if (!atDigit())
                fail("digits expected after '.'");
            skipDigits();
        }
        if (pos >= src.length || (src[pos] != 'e' && src[pos] != 'E'))
            return JsonValue.makeNumber(cast(string) src[start .. pos]);

        immutable mantissaEnd = pos;
        ++pos; // 'e'
        bool negative = false;
        if (pos < src.length && (src[pos] == '+' || src[pos] == '-'))
        {
            negative = src[pos] == '-';
            ++pos;
        }
        if (!atDigit())
            fail("digits expected in exponent");
        size_t d = pos;
        skipDigits();
        while (d < pos && src[d] == '0')
            ++d;
        immutable digits = src[d .. pos];

        char[] text;
        text.reserve(mantissaEnd - start + 2 + (digits.length ? digits.length : 1));
        text ~= cast(const(char)[]) src[start .. mantissaEnd];
        text ~= 'e';
        if (digits.length == 0)
            text ~= '0';
        else
        {
            if (negative)
                text ~= '-';
            text ~= cast(const(char)[]) digits;
        }
        return JsonValue.makeNumber(cast(string) text);
    }
}

version (unittest)
{
    private bool ok(string s) @safe
    {
        JsonValue v;
        return tryParse(cast(const(ubyte)[]) s, v);
    }

    private string num(string s) @safe
    {
        auto v = parse(s);
        assert(v.kind == JsonKind.number, s);
        return v.text;
    }
}

@safe unittest
{
    foreach (s; ["0", "-0", "1", "[]", "{}", "[ ]", "{ }", " \t\r\n null \n", "true", "false",
            `""`, `"a"`, `[1,2,3]`, `{"a":1}`, `[[],[[]],{}]`, `{"a":{"b":[null]}}`,
            "1e5", "1E+5", "-1.5e-3", `"é😀\/"`, `["a" , "b"]`])
        assert(ok(s), s);
}

@safe unittest
{
    foreach (s; ["", " ", "\n", "[1,]", "[,1]", "[1 2]", `{"a":1,}`, `{"a" 1}`, `{a:1}`, `{1:1}`,
            `{"a":}`, "[", "]", "{", "}", "[1", `{"a":1`, "01", "+1", "-", "1.", ".5", "1e", "1e+",
            "1E+-5", "1e5e5", "0x1", "- 1", "1 .5", "True", "NaN", "Infinity", "-Infinity", "nul",
            "nulll", "'a'", "// c\n1", "1 2", "[1]]", "\f1", "\v1", "1\0", "\u00A01", "\u20281", "\u00851", "1\u00A0",
            `"abc`, `"\"`, `["\`, "\"a\tb\"", "\"a\nb\"", `"\x"`, `"\U0041"`, `"\'"`, `"\0"`,
            `"\u12"`, `"\u12G4"`, `"\u００４１"`, `"\uD800"`, `"\uD800A"`, `"\uD800"`,
            `"\uD800\uDBFF"`, `"\uDC00"`, `"\uD800x"`, `{"\uD800":1}`, `{"a":"\uD800","a":1}`,
            `{"a":[1,],"a":1}`, "٢", "١", "[²]"])
        assert(!ok(s), s);
}

@safe unittest
{
    assert(!ok("\xEF\xBB\xBF1")); // BOM
    assert(!parseBytesOk([0x22, 0xFF, 0x22])); // invalid UTF-8
    assert(!parseBytesOk([0x22, 0xED, 0xA0, 0x80, 0x22])); // raw surrogate
    assert(!parseBytesOk([0x22, 0xC0, 0x80, 0x22])); // overlong
    assert(!parseBytesOk([0x22, 0xF4, 0x90, 0x80, 0x80, 0x22])); // > U+10FFFF
    assert(parseBytesOk([0x22, 0xF0, 0x9F, 0x98, 0x80, 0x22]));
}

version (unittest) private bool parseBytesOk(const(ubyte)[] b) @safe
{
    JsonValue v;
    return tryParse(b, v);
}

@safe unittest
{
    // Number normalisation.
    assert(num("1.0") == "1.0");
    assert(num("1.50") == "1.50");
    assert(num("1E5") == "1e5");
    assert(num("1e+05") == "1e5");
    assert(num("1e-007") == "1e-7");
    assert(num("1e-0") == "1e0");
    assert(num("1E+00") == "1e0");
    assert(num("-0.0") == "-0.0");
    assert(num("0e0") == "0e0");
    assert(num("2.5E-000789") == "2.5e-789");
    assert(num("-0") == "-0");
    assert(num("123456789012345678901234567890") == "123456789012345678901234567890");
    assert(num("0.000e-0") == "0.000e0");
}

@safe unittest
{
    // String decoding.
    assert(parse(`"a\"b\\c\/d\b\f\n\r\t"`).text == "a\"b\\c/d\b\f\n\r\t");
    assert(parse(`"Aéé"`).text == "Aéé");
    assert(parse(`"😀"`).text == "\U0001F600");
    assert(parse(`"\u0000"`).text == "\0");
    assert(parse("\"\u007f \"").text == "\u007f ");
    assert(parse(`"plain ascii"`).text == "plain ascii");
    assert(parse(`"mixed \n and plain"`).text == "mixed \n and plain");
}

@safe unittest
{
    // Structure.
    auto v = parse(`{"b":[1,2],"a":"x","b":null}`);
    assert(v.kind == JsonKind.object);
    assert(v.members.length == 3); // duplicates kept
    assert(v.members[0].key == "b" && v.members[0].value.items.length == 2);
    assert(v.members[2].value.kind == JsonKind.null_);
}

@safe unittest
{
    import std.array : replicate;

    // Depth limits.
    assert(ok("[".replicate(512) ~ "]".replicate(512)));
    assert(!ok("[".replicate(513) ~ "]".replicate(513)));
    assert(!ok("[".replicate(512) ~ "{}" ~ "]".replicate(512)));
    assert(ok("[".replicate(511) ~ "{}" ~ "]".replicate(511)));
    assert(ok(`{"a":`.replicate(512) ~ "1" ~ "}".replicate(512)));
    assert(!ok(`{"a":`.replicate(513) ~ "1" ~ "}".replicate(513)));
    assert(!ok("[".replicate(100_000)));
    // An over-deep value under a repeated key is still invalid.
    assert(!ok(`{"a":` ~ "[".replicate(513) ~ "]".replicate(513) ~ `,"a":1}`));
    // Scalars don't count towards depth.
    assert(ok("[".replicate(511) ~ "1" ~ "]".replicate(511)));
}

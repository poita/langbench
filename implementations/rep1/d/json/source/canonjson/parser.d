/**
 * Single-pass recursive-descent JSON parser working on bytes.
 *
 * The parser accepts exactly the RFC 8259 grammar (see SPEC.md): four ASCII
 * whitespace bytes, strict numbers, strict strings with surrogate-pair
 * checking, and a maximum nesting depth of $(LREF maxDepth). Input bytes must
 * be well-formed UTF-8 without a byte-order mark; this is checked first, in
 * one linear pass.
 */
module canonjson.parser;

import std.array : Appender;

import canonjson.buffer : ByteBuffer;
import canonjson.scan : skipPlain;
import canonjson.utf8 : encodeUtf8, hasByteOrderMark, validateUtf8;
import canonjson.value : Kind, Member, Value;

/// Maximum supported nesting depth of arrays and objects.
enum maxDepth = 512;

/// Thrown by $(LREF parse) when the document is invalid.
class ParseException : Exception
{
    /// Byte offset at which the problem was detected.
    size_t offset;

    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/**
 * Parses a complete document.
 *
 * Params:
 *   input = the whole document as bytes
 * Returns: the value tree. Escape-free strings and plain numbers borrow from
 *   `input`, which must therefore not be modified or freed while the tree is in use.
 * Throws: $(LREF ParseException) if the document is not valid.
 */
Value parse(const(ubyte)[] input) @safe
{
    if (hasByteOrderMark(input))
        throw new ParseException("byte-order mark not allowed", 0);
    if (!validateUtf8(input))
        throw new ParseException("invalid UTF-8", 0);
    auto p = Parser(input);
    return p.parseDocument();
}

/// ditto
Value parse(const(char)[] input) @trusted
{
    return parse(cast(const(ubyte)[]) input);
}

/// Like $(LREF parse) but returns false instead of throwing.
bool tryParse(const(ubyte)[] input, out Value result) @safe
{
    try
    {
        result = parse(input);
        return true;
    }
    catch (ParseException)
        return false;
}

private struct Parser
{
    const(ubyte)[] src;
    size_t pos;
    uint depth;
    // Shared scratch stacks: children are appended while a container is open
    // and copied out once when it closes.
    Appender!(Value[]) valueStack;
    Appender!(Member[]) memberStack;
    ByteBuffer scratch;

    this(const(ubyte)[] input) @safe
    {
        src = input;
    }

    noreturn fail(string msg) @safe
    {
        throw new ParseException(msg, pos);
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

    Value parseDocument() @safe
    {
        skipWs();
        auto v = parseValue();
        skipWs();
        if (pos != src.length)
            fail("trailing content");
        return v;
    }

    Value parseValue() @safe
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
            return Value.makeString(parseString());
        case 't':
            expectLiteral("true");
            return Value.literal(Kind.true_);
        case 'f':
            expectLiteral("false");
            return Value.literal(Kind.false_);
        case 'n':
            expectLiteral("null");
            return Value.literal(Kind.null_);
        case '-': case '0': .. case '9':
            return parseNumber();
        default:
            fail("unexpected character");
        }
    }

    void expectLiteral(string word) @safe
    {
        if (src.length - pos < word.length)
            fail("bad literal");
        foreach (k, ch; word)
            if (src[pos + k] != ch)
                fail("bad literal");
        pos += word.length;
    }

    void enter() @safe
    {
        if (++depth > maxDepth)
            fail("nesting too deep");
        ++pos; // the opening bracket
    }

    Value parseArray() @safe
    {
        enter();
        immutable base = valueStack.data.length;
        skipWs();
        if (pos < src.length && src[pos] == ']')
            ++pos;
        else
            for (;;)
            {
                skipWs();
                auto v = parseValue();
                valueStack.put(v);
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
        --depth;
        auto items = valueStack.data[base .. $].dup;
        valueStack.shrinkTo(base);
        return Value.makeArray(items);
    }

    Value parseObject() @safe
    {
        enter();
        immutable base = memberStack.data.length;
        skipWs();
        if (pos < src.length && src[pos] == '}')
            ++pos;
        else
            for (;;)
            {
                skipWs();
                if (pos >= src.length || src[pos] != '"')
                    fail("expected string key");
                auto key = parseString();
                skipWs();
                if (pos >= src.length || src[pos] != ':')
                    fail("expected ':'");
                ++pos;
                skipWs();
                auto v = parseValue();
                memberStack.put(Member(key, v));
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
        --depth;
        auto members = memberStack.data[base .. $].dup;
        memberStack.shrinkTo(base);
        return Value.makeObject(members);
    }

    /// Parses a string starting at the opening quote; returns the decoded bytes.
    const(ubyte)[] parseString() @safe
    {
        ++pos;
        immutable start = pos;
        size_t i = skipPlain(src, start);
        if (i >= src.length)
            fail("unterminated string");
        if (src[i] == '"')
        {
            pos = i + 1;
            return src[start .. i]; // no escapes: borrow from the input
        }
        scratch.clear();
        scratch.put(src[start .. i]);
        for (;;)
        {
            // Here src[i] is '"', '\\' or a control byte.
            immutable c = src[i];
            if (c == '"')
                break;
            if (c != '\\')
            {
                pos = i;
                fail("control character in string");
            }
            i = decodeEscape(i + 1);
            immutable run = i;
            i = skipPlain(src, i);
            if (i >= src.length)
            {
                pos = i;
                fail("unterminated string");
            }
            scratch.put(src[run .. i]);
        }
        pos = i + 1;
        return scratch.data.idup;
    }

    /// Decodes the escape whose first byte after the backslash is at `i`;
    /// appends to `scratch` and returns the index after the escape.
    size_t decodeEscape(size_t i) @safe
    {
        pos = i;
        if (i >= src.length)
            fail("unterminated string");
        ubyte out_;
        switch (src[i])
        {
        case '"':  out_ = '"';  break;
        case '\\': out_ = '\\'; break;
        case '/':  out_ = '/';  break;
        case 'b':  out_ = '\b'; break;
        case 'f':  out_ = '\f'; break;
        case 'n':  out_ = '\n'; break;
        case 'r':  out_ = '\r'; break;
        case 't':  out_ = '\t'; break;
        case 'u':
            return decodeUnicodeEscape(i + 1);
        default:
            fail("bad escape");
        }
        scratch.put(out_);
        return i + 1;
    }

    /// `i` is the index of the first hex digit of a `\u` escape.
    size_t decodeUnicodeEscape(size_t i) @safe
    {
        uint cp = hex4(i);
        i += 4;
        if (cp >= 0xD800 && cp <= 0xDBFF)
        {
            if (i + 1 >= src.length || src[i] != '\\' || src[i + 1] != 'u')
            {
                pos = i;
                fail("lone high surrogate");
            }
            immutable lo = hex4(i + 2);
            if (lo < 0xDC00 || lo > 0xDFFF)
            {
                pos = i;
                fail("high surrogate not followed by low surrogate");
            }
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            i += 6;
        }
        else if (cp >= 0xDC00 && cp <= 0xDFFF)
            fail("lone low surrogate");
        encodeUtf8(scratch, cp);
        return i;
    }

    /// Reads four hex digits at `i`.
    uint hex4(size_t i) @safe
    {
        if (i + 4 > src.length)
        {
            pos = src.length;
            fail("truncated \\u escape");
        }
        uint v = 0;
        foreach (k; 0 .. 4)
        {
            immutable d = hexValue[src[i + k]];
            if (d > 15)
            {
                pos = i + k;
                fail("bad hex digit");
            }
            v = (v << 4) | d;
        }
        return v;
    }

    Value parseNumber() @safe
    {
        immutable start = pos;
        size_t i = pos;
        immutable n = src.length;
        if (src[i] == '-')
            ++i;
        if (i >= n)
            fail("bad number");
        if (src[i] == '0')
            ++i;
        else if (src[i] >= '1' && src[i] <= '9')
            while (i < n && isDigit(src[i]))
                ++i;
        else
        {
            pos = i;
            fail("bad number");
        }
        if (i < n && src[i] == '.')
        {
            ++i;
            immutable d = i;
            while (i < n && isDigit(src[i]))
                ++i;
            if (i == d)
            {
                pos = i;
                fail("bad fraction");
            }
        }
        if (i >= n || (src[i] != 'e' && src[i] != 'E'))
        {
            pos = i;
            return Value.makeNumber(src[start .. i]);
        }
        immutable mantissaEnd = i;
        ++i;
        bool negative = false;
        if (i < n && (src[i] == '+' || src[i] == '-'))
        {
            negative = src[i] == '-';
            ++i;
        }
        size_t d = i;
        while (i < n && isDigit(src[i]))
            ++i;
        if (i == d)
        {
            pos = i;
            fail("bad exponent");
        }
        pos = i;
        // Normalise the exponent: strip leading zeros; a zero exponent is "0" and unsigned.
        while (d < i - 1 && src[d] == '0')
            ++d;
        if (src[d] == '0')
            negative = false;
        auto text = new ubyte[(mantissaEnd - start) + 1 + (negative ? 1 : 0) + (i - d)];
        size_t w = mantissaEnd - start;
        text[0 .. w] = src[start .. mantissaEnd];
        text[w++] = 'e';
        if (negative)
            text[w++] = '-';
        text[w .. $] = src[d .. i];
        return Value.makeNumber(text);
    }
}

private bool isDigit(ubyte c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private immutable ubyte[256] hexValue = () {
    ubyte[256] t = 0xFF;
    foreach (c; '0' .. '9' + 1)
        t[c] = cast(ubyte)(c - '0');
    foreach (c; 'a' .. 'f' + 1)
        t[c] = cast(ubyte)(c - 'a' + 10);
    foreach (c; 'A' .. 'F' + 1)
        t[c] = cast(ubyte)(c - 'A' + 10);
    return t;
}();

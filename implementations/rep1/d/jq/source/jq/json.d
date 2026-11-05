/**
 * JSON text <-> `Value`: a single-pass recursive-descent parser and a compact
 * serialiser, both written from scratch.
 */
module jq.json;

import core.stdc.math : signbit;
import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import core.stdc.string : memcpy;

import jq.value;

/// Thrown by `parseJson` on malformed input.
class JsonException : Exception
{
    /// Byte offset of the problem.
    size_t offset;
    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

// ---------------------------------------------------------------------------
// Output buffer
// ---------------------------------------------------------------------------

/// A growable byte buffer used for serialisation.
struct Buffer
{
    ubyte[] data;
    size_t len;

    /// Ensure room for `n` more bytes.
    void reserve(size_t n) nothrow
    {
        if (len + n > data.length)
        {
            size_t cap = data.length < 256 ? 256 : data.length * 2;
            while (cap < len + n)
                cap *= 2;
            data.length = cap;
        }
    }

    /// Append one byte.
    void put(char c) nothrow
    {
        if (len == data.length)
            reserve(1);
        data[len++] = cast(ubyte) c;
    }

    /// Append a run of bytes.
    void put(const(char)[] s) nothrow @trusted
    {
        if (s.length == 0)
            return;
        reserve(s.length);
        memcpy(data.ptr + len, s.ptr, s.length);
        len += s.length;
    }

    /// Discard the contents (keeps capacity).
    void clear() pure nothrow @safe @nogc { len = 0; }

    /// The bytes written so far.
    const(char)[] text() const pure nothrow @trusted @nogc
    {
        return cast(const(char)[]) data[0 .. len];
    }
}

private static immutable char[16] hexDigits = "0123456789abcdef";

private static immutable bool[256] needsEscape = () {
    bool[256] t;
    foreach (i; 0 .. 0x20)
        t[i] = true;
    t['"'] = true;
    t['\\'] = true;
    t[0x7f] = true;
    return t;
}();

/// Append `s` as a JSON string literal (with quotes).
void putString(ref Buffer b, string s) nothrow @trusted
{
    b.reserve(s.length + 2);
    b.put('"');
    size_t runStart = 0;
    foreach (i; 0 .. s.length)
    {
        const c = cast(ubyte) s[i];
        if (!needsEscape[c])
            continue;
        if (i > runStart)
            b.put(s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"': b.put(`\"`); break;
        case '\\': b.put(`\\`); break;
        case '\b': b.put(`\b`); break;
        case '\f': b.put(`\f`); break;
        case '\n': b.put(`\n`); break;
        case '\r': b.put(`\r`); break;
        case '\t': b.put(`\t`); break;
        default:
            b.put(`\u00`);
            b.put(hexDigits[c >> 4]);
            b.put(hexDigits[c & 15]);
        }
    }
    if (s.length > runStart)
        b.put(s[runStart .. $]);
    b.put('"');
}

/// Append a number in jq's output form.
void putNumber(ref Buffer b, double d) nothrow @trusted
{
    if (d != d)
    {
        b.put("null");
        return;
    }
    if (d == double.infinity || d == -double.infinity)
    {
        b.put(d < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308");
        return;
    }
    if (d > -9007199254740992.0 && d < 9007199254740992.0 && d == cast(double)(cast(long) d))
    {
        long n = cast(long) d;
        if (n == 0)
        {
            b.put(signbit(d) ? "-0" : "0");
            return;
        }
        char[24] tmp = void;
        size_t p = tmp.length;
        const neg = n < 0;
        ulong u = neg ? -cast(ulong) n : cast(ulong) n;
        while (u != 0)
        {
            tmp[--p] = cast(char)('0' + u % 10);
            u /= 10;
        }
        if (neg)
            tmp[--p] = '-';
        b.put(tmp[p .. $]);
        return;
    }
    char[40] buf = void;
    int n;
    foreach (prec; 15 .. 18)
    {
        n = snprintf(buf.ptr, buf.length, "%.*g", prec, d);
        if (prec == 17 || strtod(buf.ptr, null) == d)
            break;
    }
    // strip trailing zeros of the mantissa
    size_t end = n;
    size_t ePos = n;
    foreach (i; 0 .. n)
        if (buf[i] == 'e')
        {
            ePos = i;
            break;
        }
    size_t mEnd = ePos;
    bool hasDot = false;
    foreach (i; 0 .. ePos)
        if (buf[i] == '.')
            hasDot = true;
    if (hasDot)
    {
        while (mEnd > 0 && buf[mEnd - 1] == '0')
            --mEnd;
        if (mEnd > 0 && buf[mEnd - 1] == '.')
            --mEnd;
    }
    b.put(buf[0 .. mEnd]);
    if (ePos < end)
        b.put(buf[ePos .. end]);
}

/// Append the compact JSON text of `v`.
void writeValue(ref Buffer b, Value v) nothrow
{
    final switch (v.type)
    {
    case Type.null_: b.put("null"); break;
    case Type.false_: b.put("false"); break;
    case Type.true_: b.put("true"); break;
    case Type.number: putNumber(b, v.num); break;
    case Type.string: putString(b, v.str.s); break;
    case Type.error: b.put("null"); break;
    case Type.array:
        b.put('[');
        foreach (i, e; v.arr.items)
        {
            if (i)
                b.put(',');
            writeValue(b, e);
        }
        b.put(']');
        break;
    case Type.object:
        b.put('{');
        auto o = v.obj;
        foreach (i; 0 .. o.keys.length)
        {
            if (i)
                b.put(',');
            putString(b, o.keys[i].s);
            b.put(':');
            writeValue(b, o.vals[i]);
        }
        b.put('}');
        break;
    }
}

/// Compact JSON text of a value.
string toJson(Value v) nothrow
{
    Buffer b;
    writeValue(b, v);
    return b.text.idup;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

private static immutable double[23] pow10tab = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
    1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
];

/**
 * Parse the numeric literal in `s[pos .. $]` following JSON number syntax.
 * Returns the end offset, or `size_t.max` if there is no valid number there.
 */
size_t scanNumber(string s, size_t pos, out double result) nothrow @trusted
{
    const start = pos;
    const n = s.length;
    bool neg = false;
    if (pos < n && s[pos] == '-')
    {
        neg = true;
        ++pos;
    }
    if (pos >= n)
        return size_t.max;
    ulong mant = 0;
    int digits = 0; // significant digits accumulated into mant
    int fracDigits = 0;
    bool exact = true;
    if (s[pos] == '0')
    {
        ++pos;
    }
    else if (s[pos] >= '1' && s[pos] <= '9')
    {
        while (pos < n && s[pos] >= '0' && s[pos] <= '9')
        {
            if (digits < 18)
                mant = mant * 10 + (s[pos] - '0');
            else
                exact = false;
            ++digits;
            ++pos;
        }
    }
    else
        return size_t.max;
    bool simple = true;
    if (pos < n && s[pos] == '.')
    {
        ++pos;
        const fs = pos;
        while (pos < n && s[pos] >= '0' && s[pos] <= '9')
        {
            if (digits < 18)
            {
                mant = mant * 10 + (s[pos] - '0');
                if (mant != 0)
                    ++digits;
                ++fracDigits;
            }
            else
                exact = false;
            ++pos;
        }
        if (pos == fs)
            return size_t.max;
    }
    if (pos < n && (s[pos] == 'e' || s[pos] == 'E'))
    {
        simple = false;
        ++pos;
        if (pos < n && (s[pos] == '+' || s[pos] == '-'))
            ++pos;
        const es = pos;
        while (pos < n && s[pos] >= '0' && s[pos] <= '9')
            ++pos;
        if (pos == es)
            return size_t.max;
    }
    if (simple && exact && mant < (1UL << 53) && fracDigits <= 22)
    {
        double d = cast(double) mant;
        if (fracDigits)
            d /= pow10tab[fracDigits];
        result = neg ? -d : d;
        return pos;
    }
    char[64] stack = void;
    const len = pos - start;
    if (len < stack.length)
    {
        memcpy(stack.ptr, s.ptr + start, len);
        stack[len] = 0;
        result = strtod(stack.ptr, null);
    }
    else
    {
        auto heap = new char[len + 1];
        memcpy(heap.ptr, s.ptr + start, len);
        heap[len] = 0;
        result = strtod(heap.ptr, null);
    }
    return pos;
}

/// Append the UTF-8 encoding of code point `cp` to `dst`.
void encodeUtf8(ref char[] dst, uint cp) nothrow
{
    if (cp < 0x80)
        dst ~= cast(char) cp;
    else if (cp < 0x800)
    {
        dst ~= cast(char)(0xC0 | (cp >> 6));
        dst ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        dst ~= cast(char)(0xE0 | (cp >> 12));
        dst ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        dst ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        dst ~= cast(char)(0xF0 | (cp >> 18));
        dst ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        dst ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        dst ~= cast(char)(0x80 | (cp & 0x3F));
    }
}

private struct Parser
{
    string src;
    size_t pos;
    JStr[string] keyCache;
    Value[] vstack;
    JStr[] kstack;
    size_t vtop, ktop;

    JsonException fail(string msg) const pure nothrow @safe
    {
        return new JsonException(msg, pos);
    }

    void skipWs() nothrow @trusted
    {
        const n = src.length;
        while (pos < n)
        {
            const c = src[pos];
            if (c == ' ' || c == '\n' || c == '\t' || c == '\r')
                ++pos;
            else
                break;
        }
    }

    Value parseValue(int depth)
    {
        skipWs();
        if (pos >= src.length)
            throw fail("unexpected end of input");
        if (depth > 10_000)
            throw fail("nesting too deep");
        const c = src[pos];
        switch (c)
        {
        case '{': return parseObject(depth);
        case '[': return parseArray(depth);
        case '"': return Value.makeString(parseString());
        case 't':
            expectWord("true");
            return Value.makeBool(true);
        case 'f':
            expectWord("false");
            return Value.makeBool(false);
        case 'n':
            expectWord("null");
            return Value.makeNull;
        default:
            double d;
            const e = scanNumber(src, pos, d);
            if (e == size_t.max)
                throw fail("invalid value");
            pos = e;
            return Value.makeNumber(d);
        }
    }

    void expectWord(string w)
    {
        if (pos + w.length > src.length || src[pos .. pos + w.length] != w)
            throw fail("invalid literal");
        pos += w.length;
    }

    Value parseArray(int depth)
    {
        ++pos; // [
        const base = vtop;
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            ++pos;
            return Value.makeArray(null);
        }
        while (true)
        {
            auto v = parseValue(depth + 1);
            if (vtop == vstack.length)
                vstack.length = vstack.length ? vstack.length * 2 : 256;
            vstack[vtop++] = v;
            skipWs();
            if (pos >= src.length)
                throw fail("unterminated array");
            const c = src[pos++];
            if (c == ',')
                continue;
            if (c == ']')
                break;
            --pos;
            throw fail("expected ',' or ']'");
        }
        auto items = vstack[base .. vtop].dup;
        vtop = base;
        return Value.makeArray(items);
    }

    JStr internKey(string s)
    {
        if (auto p = s in keyCache)
            return *p;
        auto k = new JStr(s);
        keyCache[s] = k;
        return k;
    }

    Value parseObject(int depth)
    {
        ++pos; // {
        const vbase = vtop;
        const kbase = ktop;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            ++pos;
            return Value.makeObject(new JObj());
        }
        while (true)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                throw fail("expected object key");
            auto key = internKey(parseString());
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                throw fail("expected ':'");
            ++pos;
            auto v = parseValue(depth + 1);
            if (vtop == vstack.length)
                vstack.length = vstack.length ? vstack.length * 2 : 256;
            if (ktop == kstack.length)
                kstack.length = kstack.length ? kstack.length * 2 : 256;
            vstack[vtop++] = v;
            kstack[ktop++] = key;
            skipWs();
            if (pos >= src.length)
                throw fail("unterminated object");
            const c = src[pos++];
            if (c == ',')
                continue;
            if (c == '}')
                break;
            --pos;
            throw fail("expected ',' or '}'");
        }
        auto keys = kstack[kbase .. ktop].dup;
        auto vals = vstack[vbase .. vtop].dup;
        vtop = vbase;
        ktop = kbase;
        return Value.makeObject(buildObject(keys, vals));
    }

    /// Build an object, resolving (never expected) duplicate keys: first position, last value.
    static JObj buildObject(JStr[] keys, Value[] vals)
    {
        bool dup = false;
        if (keys.length <= JObj.linearLimit)
        {
            foreach (i; 1 .. keys.length)
                foreach (j; 0 .. i)
                    if (keys[i] is keys[j])
                        dup = true;
        }
        else
        {
            bool[string] seen;
            foreach (k; keys)
            {
                if (k.s in seen)
                {
                    dup = true;
                    break;
                }
                seen[k.s] = true;
            }
        }
        if (!dup)
            return new JObj(keys, vals);
        auto o = new JObj();
        foreach (i, k; keys)
            o.set(k, vals[i]);
        return o;
    }

    /// Parse a string literal starting at the opening quote; returns decoded text.
    string parseString() @trusted
    {
        ++pos; // opening quote
        const start = pos;
        const n = src.length;
        while (pos < n)
        {
            const c = cast(ubyte) src[pos];
            if (c == '"')
            {
                auto r = src[start .. pos];
                ++pos;
                return r;
            }
            if (c == '\\')
                break;
            if (c < 0x20)
                throw fail("control character in string");
            ++pos;
        }
        if (pos >= n)
            throw fail("unterminated string");
        // slow path with escapes
        char[] buf;
        buf.reserve(pos - start + 16);
        buf ~= src[start .. pos];
        while (pos < n)
        {
            const c = src[pos];
            if (c == '"')
            {
                ++pos;
                return cast(string) buf;
            }
            if (c == '\\')
            {
                ++pos;
                if (pos >= n)
                    break;
                const e = src[pos++];
                switch (e)
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
                    {
                        uint cp = parseHex4();
                        if (cp >= 0xD800 && cp < 0xDC00)
                        {
                            if (pos + 1 < n && src[pos] == '\\' && src[pos + 1] == 'u')
                            {
                                const save = pos;
                                pos += 2;
                                const lo = parseHex4();
                                if (lo >= 0xDC00 && lo < 0xE000)
                                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                else
                                {
                                    pos = save;
                                    cp = 0xFFFD;
                                }
                            }
                            else
                                cp = 0xFFFD;
                        }
                        else if (cp >= 0xDC00 && cp < 0xE000)
                            cp = 0xFFFD;
                        encodeUtf8(buf, cp);
                        break;
                    }
                default:
                    --pos;
                    throw fail("invalid escape");
                }
                continue;
            }
            if (cast(ubyte) c < 0x20)
                throw fail("control character in string");
            buf ~= c;
            ++pos;
        }
        throw fail("unterminated string");
    }

    uint parseHex4() @trusted
    {
        uint v = 0;
        foreach (_; 0 .. 4)
        {
            if (pos >= src.length)
                throw fail("bad \\u escape");
            const c = src[pos++];
            uint d;
            if (c >= '0' && c <= '9')
                d = c - '0';
            else if (c >= 'a' && c <= 'f')
                d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                d = c - 'A' + 10;
            else
                throw fail("bad \\u escape");
            v = v * 16 + d;
        }
        return v;
    }
}

/**
 * Parse exactly one JSON value from `text` (surrounding whitespace allowed).
 *
 * Throws: `JsonException` if the text is not valid JSON.
 */
Value parseJson(string text)
{
    Parser p;
    p.src = text;
    auto v = p.parseValue(0);
    p.skipWs();
    if (p.pos != text.length)
        throw p.fail("trailing characters after value");
    return v;
}

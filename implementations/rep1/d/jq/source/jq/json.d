/// A from-scratch JSON parser and compact serializer.
module jq.json;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.array : Appender, appender;
import std.exception : assumeUnique;

import jq.error;
import jq.value;

/// Maximum nesting depth accepted by `parseJson`.
enum maxJsonDepth = 10_000;

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

private static immutable double[16] pow10tab = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13,
    1e14, 1e15
];

/// Scans a JSON number starting at `s[pos]`. On success returns true, stores
/// the value in `result` and advances `pos` past the number. The value is the
/// double nearest to the decimal text.
bool scanNumber(const(char)[] s, ref size_t pos, out double result) @trusted
{
    size_t p = pos;
    immutable n = s.length;
    immutable start = p;
    bool neg = false;
    if (p < n && s[p] == '-')
    {
        neg = true;
        ++p;
    }
    if (p >= n)
        return false;
    ulong mant = 0;
    int digits = 0;
    int frac = 0;
    if (s[p] == '0')
    {
        ++p;
        digits = 1;
    }
    else if (s[p] >= '1' && s[p] <= '9')
    {
        while (p < n && s[p] >= '0' && s[p] <= '9')
        {
            if (digits < 19)
                mant = mant * 10 + (s[p] - '0');
            ++digits;
            ++p;
        }
    }
    else
        return false;
    if (p < n && s[p] == '.')
    {
        ++p;
        if (p >= n || s[p] < '0' || s[p] > '9')
            return false;
        while (p < n && s[p] >= '0' && s[p] <= '9')
        {
            if (digits < 19)
                mant = mant * 10 + (s[p] - '0');
            ++digits;
            ++frac;
            ++p;
        }
    }
    bool hasExp = false;
    if (p < n && (s[p] == 'e' || s[p] == 'E'))
    {
        hasExp = true;
        ++p;
        if (p < n && (s[p] == '+' || s[p] == '-'))
            ++p;
        if (p >= n || s[p] < '0' || s[p] > '9')
            return false;
        while (p < n && s[p] >= '0' && s[p] <= '9')
            ++p;
    }
    pos = p;
    if (!hasExp && digits <= 15)
    {
        // Both operands are exactly representable, so the single division is
        // correctly rounded (Clinger's fast path).
        double v = cast(double) mant;
        if (frac > 0)
            v /= pow10tab[frac];
        result = neg ? -v : v;
        return true;
    }
    immutable len = p - start;
    char[64] stack = void;
    char[] tmp = len < stack.length ? stack[0 .. len + 1] : new char[len + 1];
    tmp[0 .. len] = s[start .. p];
    tmp[len] = 0;
    result = strtod(tmp.ptr, null);
    return true;
}

/// Parses `text` entirely as a JSON number (no surrounding whitespace).
/// Returns false if it is not one.
bool parseNumberText(const(char)[] text, out double result)
{
    size_t pos = 0;
    return scanNumber(text, pos, result) && pos == text.length;
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

private int hexVal(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private void putUtf8(ref char[] buf, ref size_t n, uint cp) pure nothrow @nogc @safe
{
    if (cp < 0x80)
        buf[n++] = cast(char) cp;
    else if (cp < 0x800)
    {
        buf[n++] = cast(char)(0xC0 | (cp >> 6));
        buf[n++] = cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        buf[n++] = cast(char)(0xE0 | (cp >> 12));
        buf[n++] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf[n++] = cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        buf[n++] = cast(char)(0xF0 | (cp >> 18));
        buf[n++] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
        buf[n++] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf[n++] = cast(char)(0x80 | (cp & 0x3F));
    }
}

/// Decodes the JSON escapes in the body of a string literal (the text between
/// the quotes). Returns the input itself when it holds no escapes.
/// Throws `JsonParseError` on a malformed escape.
string unescape(string body_) @trusted
{
    size_t i = 0;
    immutable n = body_.length;
    while (i < n && body_[i] != '\\')
        ++i;
    if (i == n)
        return body_;
    // Decoded text is never longer than the escaped text.
    auto buf = new char[n];
    size_t o = i;
    buf[0 .. i] = body_[0 .. i];
    while (i < n)
    {
        immutable c = body_[i];
        if (c != '\\')
        {
            buf[o++] = c;
            ++i;
            continue;
        }
        ++i;
        if (i >= n)
            throw new JsonParseError("truncated escape sequence");
        immutable e = body_[i++];
        switch (e)
        {
        case '"':
            buf[o++] = '"';
            break;
        case '\\':
            buf[o++] = '\\';
            break;
        case '/':
            buf[o++] = '/';
            break;
        case 'b':
            buf[o++] = '\b';
            break;
        case 'f':
            buf[o++] = '\f';
            break;
        case 'n':
            buf[o++] = '\n';
            break;
        case 'r':
            buf[o++] = '\r';
            break;
        case 't':
            buf[o++] = '\t';
            break;
        case 'u':
            {
                uint readHex4()
                {
                    if (i + 4 > n)
                        throw new JsonParseError("truncated \\u escape");
                    uint v = 0;
                    foreach (k; 0 .. 4)
                    {
                        immutable h = hexVal(body_[i + k]);
                        if (h < 0)
                            throw new JsonParseError("invalid \\u escape");
                        v = v * 16 + h;
                    }
                    i += 4;
                    return v;
                }

                uint cp = readHex4();
                if (cp >= 0xD800 && cp < 0xDC00)
                {
                    if (i + 6 <= n && body_[i] == '\\' && body_[i + 1] == 'u')
                    {
                        immutable save = i;
                        i += 2;
                        immutable lo = readHex4();
                        if (lo >= 0xDC00 && lo < 0xE000)
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        else
                        {
                            i = save;
                            cp = 0xFFFD;
                        }
                    }
                    else
                        cp = 0xFFFD;
                }
                else if (cp >= 0xDC00 && cp < 0xE000)
                    cp = 0xFFFD;
                putUtf8(buf, o, cp);
                break;
            }
        default:
            throw new JsonParseError("invalid escape sequence");
        }
    }
    return assumeUnique(buf[0 .. o]);
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Parses one JSON value (surrounded by optional whitespace) from `text`.
///
/// Strings without escapes are slices of `text`, not copies, so the result
/// keeps `text` alive. Throws `JsonParseError` on malformed input.
Value parseJson(string text)
{
    auto p = Parser(text);
    p.skipWs();
    auto v = p.parseValue(0);
    p.skipWs();
    if (p.pos != text.length)
        throw new JsonParseError("trailing characters after JSON value");
    return v;
}

private struct Parser
{
    string src;
    size_t pos;
    // Scratch stacks shared by all nesting levels.
    Value[] vstack;
    size_t vtop;
    string[] kstack;
    size_t ktop;

    this(string s)
    {
        src = s;
    }

    void skipWs() @trusted
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\n' || c == '\t' || c == '\r')
                ++pos;
            else
                break;
        }
    }

    void pushV(Value v)
    {
        if (vtop == vstack.length)
            vstack.length = vstack.length ? vstack.length * 2 : 64;
        vstack[vtop++] = v;
    }

    void pushK(string k)
    {
        if (ktop == kstack.length)
            kstack.length = kstack.length ? kstack.length * 2 : 64;
        kstack[ktop++] = k;
    }

    string parseString() @trusted
    {
        // src[pos] == '"'
        immutable start = ++pos;
        bool esc = false;
        immutable n = src.length;
        while (pos < n)
        {
            immutable c = src[pos];
            if (c == '"')
                break;
            if (c == '\\')
            {
                esc = true;
                ++pos;
                if (pos >= n)
                    break;
            }
            else if (c < 0x20)
                throw new JsonParseError("control character in string");
            ++pos;
        }
        if (pos >= n)
            throw new JsonParseError("unterminated string");
        auto body_ = src[start .. pos];
        ++pos;
        return esc ? unescape(body_) : body_;
    }

    Value parseValue(int depth)
    {
        if (depth > maxJsonDepth)
            throw new JsonParseError("nesting too deep");
        if (pos >= src.length)
            throw new JsonParseError("unexpected end of input");
        immutable c = src[pos];
        switch (c)
        {
        case '{':
            return parseObject(depth);
        case '[':
            return parseArray(depth);
        case '"':
            return Value.makeString(parseString());
        case 't':
            expectWord("true");
            return Value.makeBool(true);
        case 'f':
            expectWord("false");
            return Value.makeBool(false);
        case 'n':
            expectWord("null");
            return Value.makeNull();
        default:
            double d;
            if (!scanNumber(src, pos, d))
                throw new JsonParseError("invalid JSON value");
            return Value.makeNumber(d);
        }
    }

    void expectWord(string w)
    {
        if (pos + w.length > src.length || src[pos .. pos + w.length] != w)
            throw new JsonParseError("invalid literal");
        pos += w.length;
    }

    Value parseArray(int depth)
    {
        ++pos;
        immutable base = vtop;
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            ++pos;
            return Value.makeArray([]);
        }
        while (true)
        {
            skipWs();
            pushV(parseValue(depth + 1));
            skipWs();
            if (pos >= src.length)
                throw new JsonParseError("unterminated array");
            immutable c = src[pos++];
            if (c == ',')
                continue;
            if (c == ']')
                break;
            throw new JsonParseError("expected ',' or ']' in array");
        }
        auto arr = vstack[base .. vtop].dup;
        vtop = base;
        return Value.makeArray(arr);
    }

    Value parseObject(int depth)
    {
        ++pos;
        immutable base = vtop;
        immutable kbase = ktop;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            ++pos;
            return Value.makeObject(new JObject([], []));
        }
        while (true)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                throw new JsonParseError("expected string key in object");
            pushK(parseString());
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                throw new JsonParseError("expected ':' in object");
            ++pos;
            skipWs();
            pushV(parseValue(depth + 1));
            skipWs();
            if (pos >= src.length)
                throw new JsonParseError("unterminated object");
            immutable c = src[pos++];
            if (c == ',')
                continue;
            if (c == '}')
                break;
            throw new JsonParseError("expected ',' or '}' in object");
        }
        immutable cnt = vtop - base;
        auto keys = kstack[kbase .. ktop].dup;
        auto vals = vstack[base .. vtop].dup;
        vtop = base;
        ktop = kbase;
        if (hasDuplicates(keys))
        {
            // Repeated keys: first position, last value.
            auto b = ObjectBuilder(cnt);
            foreach (i; 0 .. cnt)
                b.set(keys[i], vals[i]);
            return Value.makeObject(b.build());
        }
        return Value.makeObject(new JObject(keys, vals));
    }
}

private bool hasDuplicates(const(string)[] keys)
{
    if (keys.length < 2)
        return false;
    if (keys.length <= 8)
    {
        foreach (i; 1 .. keys.length)
            foreach (j; 0 .. i)
                if (keys[i] == keys[j])
                    return true;
        return false;
    }
    bool[string] seen;
    foreach (k; keys)
    {
        if (k in seen)
            return true;
        seen[k] = true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Serializer
// ---------------------------------------------------------------------------

/// Output sink used by the serializer.
alias JsonBuffer = Appender!(char[]);

/// Appends the compact JSON text of `v` to `buf`.
void writeJson(ref JsonBuffer buf, Value v)
{
    final switch (v.kind)
    {
    case Kind.Null:
        buf.put("null");
        break;
    case Kind.False:
        buf.put("false");
        break;
    case Kind.True:
        buf.put("true");
        break;
    case Kind.Number:
        writeNumber(buf, v.num);
        break;
    case Kind.String:
        writeString(buf, v.str);
        break;
    case Kind.Array:
        buf.put('[');
        foreach (i, e; v.arr)
        {
            if (i)
                buf.put(',');
            writeJson(buf, e);
        }
        buf.put(']');
        break;
    case Kind.Object:
        {
            buf.put('{');
            auto o = v.obj;
            foreach (i; 0 .. o.length)
            {
                if (i)
                    buf.put(',');
                writeString(buf, o.keys[i]);
                buf.put(':');
                writeJson(buf, o.vals[i]);
            }
            buf.put('}');
            break;
        }
    }
}

/// The compact JSON text of `v`.
string toJson(Value v)
{
    auto buf = appender!(char[])();
    writeJson(buf, v);
    return assumeUnique(buf.data);
}

/// Appends `s` as a JSON string literal. Only `"`, `\` and control
/// characters (and U+007F) are escaped; everything else is emitted raw.
void writeString(ref JsonBuffer buf, const(char)[] s) @trusted
{
    static immutable hexd = "0123456789abcdef";
    buf.put('"');
    size_t runStart = 0;
    foreach (i; 0 .. s.length)
    {
        immutable c = cast(ubyte) s[i];
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7f)
            continue;
        if (i > runStart)
            buf.put(s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"':
            buf.put(`\"`);
            break;
        case '\\':
            buf.put(`\\`);
            break;
        case '\b':
            buf.put(`\b`);
            break;
        case '\f':
            buf.put(`\f`);
            break;
        case '\n':
            buf.put(`\n`);
            break;
        case '\r':
            buf.put(`\r`);
            break;
        case '\t':
            buf.put(`\t`);
            break;
        default:
            {
                char[6] e = ['\\', 'u', '0', '0', hexd[c >> 4], hexd[c & 15]];
                buf.put(e[]);
            }
        }
    }
    if (s.length > runStart)
        buf.put(s[runStart .. $]);
    buf.put('"');
}

/// Appends a number: integral values as integers, others in the shortest
/// `%.15g`/`%.16g`/`%.17g` form that round-trips.
void writeNumber(ref JsonBuffer buf, double d) @trusted
{
    if (d != d)
    {
        buf.put("null");
        return;
    }
    if (d == cast(long) d && d > -1e17 && d < 1e17)
    {
        long l = cast(long) d;
        if (l == 0)
        {
            buf.put(d is -0.0 ? "-0" : "0");
            return;
        }
        char[24] tmp = void;
        size_t i = tmp.length;
        immutable neg = l < 0;
        ulong u = neg ? -cast(ulong) l : cast(ulong) l;
        while (u != 0)
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        if (neg)
            tmp[--i] = '-';
        buf.put(tmp[i .. $]);
        return;
    }
    char[40] tmp = void;
    foreach (prec; 15 .. 18)
    {
        immutable len = snprintf(tmp.ptr, tmp.length, "%.*g", prec, d);
        if (prec == 17 || strtod(tmp.ptr, null) == d)
        {
            buf.put(tmp[0 .. len]);
            return;
        }
    }
}

unittest
{
    assert(toJson(parseJson(` { "a" : [1, 2.5, -3, "x\ny", null, true, false], "b": {} } `))
            == `{"a":[1,2.5,-3,"x\ny",null,true,false],"b":{}}`);
    assert(toJson(parseJson(`"😀 é \u007f \u001f /"`)) == "\"😀 é \\u007f \\u001f /\"");
    assert(toJson(parseJson("3086419725308.5")) == "3086419725308.5");
    assert(toJson(parseJson("0.125")) == "0.125");
    assert(toJson(parseJson("0.001")) == "0.001");
    assert(toJson(parseJson("1000000000000")) == "1000000000000");
    assert(toJson(parseJson("0.1")) == "0.1");
    assert(toJson(parseJson("4975.77")) == "4975.77");
}

unittest
{
    import std.exception : assertThrown;

    foreach (bad; ["", "{", "[1,", "[1 2]", `{"a" 1}`, `"abc`, "tru", "01", "1.", "-", "[1]x", `"\x"`])
        assertThrown!JsonParseError(parseJson(bad));
}

unittest
{
    // repeated keys: first position, last value
    assert(toJson(parseJson(`{"a":1,"b":2,"a":3}`)) == `{"a":3,"b":2}`);
    double d;
    assert(parseNumberText("-2.5", d) && d == -2.5);
    assert(!parseNumberText("1.0x", d) && !parseNumberText("", d));
    assert(parseNumberText("12345678901234567890123", d) && d == 12345678901234567890123.0);
}

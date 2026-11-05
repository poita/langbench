/**
 * JSON text <-> $(REF Value, jq,value): a hand-written recursive-descent parser
 * and a compact serialiser.
 *
 * The parser interns object keys (one shared $(REF JStr, jq,value) per distinct key
 * text) and slices unescaped strings straight out of the input text.
 */
module jq.json;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import std.array : Appender;

import jq.value;

/// Thrown for malformed JSON text.
class JsonException : Exception
{
    ///
    this(string msg, size_t offset = 0, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }

    /// Byte offset in the input where the problem was detected.
    size_t offset;
}

// ---------------------------------------------------------------------------
// Output buffer
// ---------------------------------------------------------------------------

/// A growable byte buffer used by the serialiser.
struct TextBuffer
{
    private char[] data;
    private size_t len;

    /// The bytes written so far.
    const(char)[] opSlice() const pure nothrow @nogc @safe
    {
        return data[0 .. len];
    }

    /// Number of bytes written.
    size_t length() const pure nothrow @nogc @safe
    {
        return len;
    }

    /// Discard the contents, keeping the allocation.
    void clear() pure nothrow @nogc @safe
    {
        len = 0;
    }

    private void grow(size_t need) pure nothrow @safe
    {
        size_t cap = data.length < 256 ? 256 : data.length * 2;
        while (cap < len + need)
            cap *= 2;
        data.length = cap;
    }

    /// Append one byte.
    void put(char c) pure nothrow @safe
    {
        if (len == data.length)
            grow(1);
        data[len++] = c;
    }

    /// Append a string.
    void put(const(char)[] s) pure nothrow @safe
    {
        if (len + s.length > data.length)
            grow(s.length);
        data[len .. len + s.length] = s[];
        len += s.length;
    }
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

private immutable double[16] pow10tab = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15
];

/**
 * Parse a JSON number starting at `s[pos]`. On success advances `pos` past it
 * and returns true; returns false (leaving `pos` unchanged) if there is no
 * well-formed number there. Doubles are correctly rounded.
 */
bool scanNumber(const(char)[] s, ref size_t pos, out double result) nothrow @trusted
{
    size_t i = pos;
    immutable n = s.length;
    bool neg = false;
    if (i < n && s[i] == '-')
    {
        neg = true;
        ++i;
    }
    if (i >= n || s[i] < '0' || s[i] > '9')
        return false;
    ulong mant = 0;
    int digits = 0;
    if (s[i] == '0')
    {
        ++i;
    }
    else
    {
        while (i < n && s[i] >= '0' && s[i] <= '9')
        {
            mant = mant * 10 + (s[i] - '0');
            ++digits;
            ++i;
        }
    }
    int frac = 0;
    bool simple = true;
    if (i < n && s[i] == '.')
    {
        ++i;
        if (i >= n || s[i] < '0' || s[i] > '9')
            return false;
        while (i < n && s[i] >= '0' && s[i] <= '9')
        {
            if (digits < 15)
                mant = mant * 10 + (s[i] - '0');
            else
                simple = false;
            ++digits;
            ++frac;
            ++i;
        }
    }
    if (i < n && (s[i] == 'e' || s[i] == 'E'))
    {
        size_t j = i + 1;
        if (j < n && (s[j] == '+' || s[j] == '-'))
            ++j;
        if (j >= n || s[j] < '0' || s[j] > '9')
            return false;
        while (j < n && s[j] >= '0' && s[j] <= '9')
            ++j;
        i = j;
        simple = false;
    }
    if (digits > 15)
        simple = false;
    if (simple)
    {
        double d = cast(double) mant;
        if (frac > 0)
            d /= pow10tab[frac];
        result = neg ? -d : d;
    }
    else
    {
        immutable len = i - pos;
        char[64] stack = void;
        char[] tmp = len < stack.length ? stack[0 .. len + 1] : new char[](len + 1);
        tmp[0 .. len] = s[pos .. i];
        tmp[len] = 0;
        result = strtod(tmp.ptr, null);
    }
    pos = i;
    return true;
}

/// Append the jq text of a number: integers without a decimal point, other values in the shortest form that round-trips.
void writeNumber(ref TextBuffer buf, double d) pure nothrow @trusted
{
    if (d >= -9007199254740992.0 && d <= 9007199254740992.0)
    {
        immutable long l = cast(long) d;
        if (cast(double) l == d)
        {
            writeInteger(buf, l);
            return;
        }
    }
    if (d != d)
    {
        buf.put("null"); // jq prints NaN as null
        return;
    }
    if (d > double.max)
    {
        buf.put("1.7976931348623157e+308");
        return;
    }
    if (d < -double.max)
    {
        buf.put("-1.7976931348623157e+308");
        return;
    }
    char[40] tmp = void;
    foreach (prec; 15 .. 18)
    {
        // snprintf/strtod are not pure, but their result depends only on the arguments.
        immutable len = formatG(tmp[], prec, d);
        if (prec == 17 || parseBack(tmp[0 .. len]) == d)
        {
            buf.put(tmp[0 .. len]);
            return;
        }
    }
}

private int formatG(char[] tmp, int prec, double d) pure nothrow @trusted
{
    static int impl(char[] tmp, int prec, double d) nothrow @nogc
    {
        return snprintf(tmp.ptr, tmp.length, "%.*g", prec, d);
    }

    alias PureImpl = int function(char[], int, double) pure nothrow @nogc;
    return (cast(PureImpl)&impl)(tmp, prec, d);
}

private double parseBack(const(char)[] s) pure nothrow @trusted
{
    static double impl(const(char)[] s) nothrow
    {
        char[64] tmp = void;
        tmp[0 .. s.length] = s[];
        tmp[s.length] = 0;
        return strtod(tmp.ptr, null);
    }

    alias PureImpl = double function(const(char)[]) pure nothrow;
    return (cast(PureImpl)&impl)(s);
}

private void writeInteger(ref TextBuffer buf, long l) pure nothrow @safe
{
    char[24] tmp = void;
    size_t p = tmp.length;
    bool neg = l < 0;
    ulong u = neg ? -cast(ulong) l : cast(ulong) l;
    do
    {
        tmp[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u != 0);
    if (neg)
        tmp[--p] = '-';
    buf.put(tmp[p .. $]);
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

private void appendUtf8(ref Appender!(char[]) out_, uint cp) pure nothrow @safe
{
    if (cp < 0x80)
        out_.put(cast(char) cp);
    else if (cp < 0x800)
    {
        out_.put(cast(char)(0xC0 | (cp >> 6)));
        out_.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        out_.put(cast(char)(0xE0 | (cp >> 12)));
        out_.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        out_.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        out_.put(cast(char)(0xF0 | (cp >> 18)));
        out_.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        out_.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        out_.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

private uint readHex4(string s, size_t at) pure @safe
{
    if (at + 4 > s.length)
        throw new JsonException("truncated \\u escape", at);
    uint v = 0;
    foreach (k; 0 .. 4)
    {
        immutable h = hexVal(s[at + k]);
        if (h < 0)
            throw new JsonException("bad \\u escape", at);
        v = v * 16 + h;
    }
    return v;
}

/**
 * Decode the JSON string literal whose opening quote is at `s[pos]`; advances
 * `pos` past the closing quote. Strings without escapes are returned as slices of `s`.
 */
string readJsonString(string s, ref size_t pos) pure @trusted
{
    assert(s[pos] == '"');
    size_t i = pos + 1;
    immutable start = i;
    while (i < s.length && s[i] != '"' && s[i] != '\\')
        ++i;
    if (i >= s.length)
        throw new JsonException("unterminated string", pos);
    if (s[i] == '"')
    {
        pos = i + 1;
        return s[start .. i];
    }
    Appender!(char[]) out_;
    out_.put(s[start .. i]);
    while (true)
    {
        if (i >= s.length)
            throw new JsonException("unterminated string", pos);
        immutable c = s[i];
        if (c == '"')
        {
            ++i;
            break;
        }
        if (c != '\\')
        {
            immutable runStart = i;
            while (i < s.length && s[i] != '"' && s[i] != '\\')
                ++i;
            out_.put(s[runStart .. i]);
            continue;
        }
        ++i;
        if (i >= s.length)
            throw new JsonException("unterminated string", pos);
        immutable e = s[i++];
        switch (e)
        {
        case '"':
            out_.put('"');
            break;
        case '\\':
            out_.put('\\');
            break;
        case '/':
            out_.put('/');
            break;
        case 'b':
            out_.put('\b');
            break;
        case 'f':
            out_.put('\f');
            break;
        case 'n':
            out_.put('\n');
            break;
        case 'r':
            out_.put('\r');
            break;
        case 't':
            out_.put('\t');
            break;
        case 'u':
            {
                uint cp = readHex4(s, i);
                i += 4;
                if (cp >= 0xD800 && cp <= 0xDBFF && i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u')
                {
                    immutable lo = readHex4(s, i + 2);
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                    {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                }
                if (cp >= 0xD800 && cp <= 0xDFFF)
                    cp = 0xFFFD; // unpaired surrogate
                appendUtf8(out_, cp);
                break;
            }
        default:
            throw new JsonException("bad escape", i - 1);
        }
    }
    pos = i;
    return cast(string) out_.data;
}

/// Append `s` as a JSON string literal (quotes included).
void writeJsonString(ref TextBuffer buf, const(char)[] s) pure nothrow @trusted
{
    static immutable char[16] hex = "0123456789abcdef";
    buf.put('"');
    size_t run = 0;
    foreach (i; 0 .. s.length)
    {
        immutable c = cast(ubyte) s[i];
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F)
            continue;
        if (i > run)
            buf.put(s[run .. i]);
        run = i + 1;
        switch (c)
        {
        case '"':
            buf.put("\\\"");
            break;
        case '\\':
            buf.put("\\\\");
            break;
        case '\b':
            buf.put("\\b");
            break;
        case '\f':
            buf.put("\\f");
            break;
        case '\n':
            buf.put("\\n");
            break;
        case '\r':
            buf.put("\\r");
            break;
        case '\t':
            buf.put("\\t");
            break;
        default:
            buf.put("\\u00");
            buf.put(hex[c >> 4]);
            buf.put(hex[c & 15]);
            break;
        }
    }
    if (s.length > run)
        buf.put(s[run .. $]);
    buf.put('"');
}

// ---------------------------------------------------------------------------
// Serialiser
// ---------------------------------------------------------------------------

/// Append the compact JSON text of `v` (no whitespace; objects in insertion order).
void writeJson(ref TextBuffer buf, Value v) pure nothrow @trusted
{
    final switch (v.kind)
    {
    case Kind.null_:
        buf.put("null");
        break;
    case Kind.false_:
        buf.put("false");
        break;
    case Kind.true_:
        buf.put("true");
        break;
    case Kind.number:
        writeNumber(buf, v.num);
        break;
    case Kind.string_:
        writeJsonString(buf, v.str);
        break;
    case Kind.array:
        {
            buf.put('[');
            bool first = true;
            foreach (x; v.items)
            {
                if (!first)
                    buf.put(',');
                first = false;
                writeJson(buf, x);
            }
            buf.put(']');
            break;
        }
    case Kind.object:
        {
            buf.put('{');
            bool first = true;
            foreach (ref e; v.obj.entries)
            {
                if (!first)
                    buf.put(',');
                first = false;
                writeJsonString(buf, e.key.s);
                buf.put(':');
                writeJson(buf, e.val);
            }
            buf.put('}');
            break;
        }
    }
}

/// The compact JSON text of `v`.
string toJson(Value v) pure nothrow @trusted
{
    TextBuffer b;
    writeJson(b, v);
    return b[].idup;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

private struct Parser
{
    string src;
    size_t pos;
    JStr[string] keys;
    Value[] vstack; // scratch stacks for elements of the containers being parsed
    Entry[] estack;
    size_t vtop, etop;
    int depth;

    void skipWs() pure nothrow @nogc @safe
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

    JsonException err(string m) const pure nothrow @safe
    {
        return new JsonException(m, pos);
    }

    bool literal(string word) pure nothrow @nogc @safe
    {
        if (pos + word.length <= src.length && src[pos .. pos + word.length] == word)
        {
            pos += word.length;
            return true;
        }
        return false;
    }

    JStr intern(string text) nothrow
    {
        if (auto p = text in keys)
            return *p;
        auto k = new JStr(text);
        keys[text] = k;
        return k;
    }

    Value parseValue() @trusted
    {
        skipWs();
        if (pos >= src.length)
            throw err("unexpected end of input");
        switch (src[pos])
        {
        case '{':
            return parseObject();
        case '[':
            return parseArray();
        case '"':
            return Value.string_(readJsonString(src, pos));
        case 't':
            if (literal("true"))
                return Value.boolean(true);
            throw err("invalid literal");
        case 'f':
            if (literal("false"))
                return Value.boolean(false);
            throw err("invalid literal");
        case 'n':
            if (literal("null"))
                return Value.nullValue;
            throw err("invalid literal");
        default:
            double d;
            if (scanNumber(src, pos, d))
                return Value.number(d);
            throw err("unexpected character");
        }
    }

    Value parseArray() @trusted
    {
        if (++depth > 10_000)
            throw err("nesting too deep");
        ++pos; // [
        immutable base = vtop;
        skipWs();
        if (pos < src.length && src[pos] == ']')
            ++pos;
        else
            while (true)
            {
                auto v = parseValue();
                if (vtop == vstack.length)
                    vstack.length = vstack.length < 64 ? 64 : vstack.length * 2;
                vstack[vtop++] = v;
                skipWs();
                if (pos >= src.length)
                    throw err("unterminated array");
                if (src[pos] == ',')
                {
                    ++pos;
                    continue;
                }
                if (src[pos] == ']')
                {
                    ++pos;
                    break;
                }
                throw err("expected ',' or ']'");
            }
        auto items = vstack[base .. vtop].dup;
        vtop = base;
        --depth;
        return Value.array(items);
    }

    Value parseObject() @trusted
    {
        if (++depth > 10_000)
            throw err("nesting too deep");
        ++pos; // {
        immutable base = etop;
        skipWs();
        if (pos < src.length && src[pos] == '}')
            ++pos;
        else
            while (true)
            {
                skipWs();
                if (pos >= src.length || src[pos] != '"')
                    throw err("expected object key");
                auto key = intern(readJsonString(src, pos));
                skipWs();
                if (pos >= src.length || src[pos] != ':')
                    throw err("expected ':'");
                ++pos;
                auto v = parseValue();
                if (etop == estack.length)
                    estack.length = estack.length < 64 ? 64 : estack.length * 2;
                estack[etop++] = Entry(key, v);
                skipWs();
                if (pos >= src.length)
                    throw err("unterminated object");
                if (src[pos] == ',')
                {
                    ++pos;
                    continue;
                }
                if (src[pos] == '}')
                {
                    ++pos;
                    break;
                }
                throw err("expected ',' or '}'");
            }
        auto ents = estack[base .. etop];
        auto obj = new JObject(ents.length);
        foreach (ref e; ents)
            obj.set(e.key, e.val); // later duplicates replace earlier values
        etop = base;
        --depth;
        return Value.object(obj);
    }
}

/**
 * Parse one JSON value (RFC 8259) from `text`; only whitespace may surround it.
 * Throws $(LREF JsonException) on malformed input.
 */
Value parseJson(string text) @trusted
{
    auto p = Parser(text);
    auto v = p.parseValue();
    p.skipWs();
    if (p.pos != text.length)
        throw p.err("trailing characters after JSON value");
    return v;
}

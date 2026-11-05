/// A hand-written JSON parser and serializer.
module jq.json;

import jq.buffer;
import jq.errors;
import jq.number;
import jq.value;

/// Parse one JSON document from `text` (surrounding whitespace allowed).
///
/// Strings without escapes, including object keys, are slices of `text`
/// itself (no copy), so keys are shared storage. Throws `ParseError`.
Value parseJson(string text)
{
    auto p = JsonParser(text);
    p.skipWs();
    auto v = p.parseValue(0);
    p.skipWs();
    if (p.pos != text.length)
        p.fail("trailing characters after JSON value");
    return v;
}

private struct JsonParser
{
    string src;
    size_t pos;
    Value[] vstack;
    size_t vsp;
    Entry[] estack;
    size_t esp;

    this(string s)
    {
        src = s;
        vstack = new Value[64];
        estack = new Entry[64];
    }

    void fail(string msg)
    {
        throw new ParseError(msg);
    }

    void skipWs() nothrow @nogc
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

    void pushV(Value v) nothrow
    {
        if (vsp == vstack.length)
            vstack.length = vstack.length * 2;
        vstack[vsp++] = v;
    }

    void pushE(Entry e) nothrow
    {
        if (esp == estack.length)
            estack.length = estack.length * 2;
        estack[esp++] = e;
    }

    Value parseValue(int depth)
    {
        if (pos >= src.length)
            fail("unexpected end of input");
        if (depth > 10_000)
            fail("nesting too deep");
        immutable c = src[pos];
        switch (c)
        {
        case '{':
            return parseObject(depth);
        case '[':
            return parseArray(depth);
        case '"':
            return mkStr(parseString());
        case 't':
            expectWord("true");
            return mkBool(true);
        case 'f':
            expectWord("false");
            return mkBool(false);
        case 'n':
            expectWord("null");
            return mkNull();
        default:
            if (c == '-' || (c >= '0' && c <= '9'))
                return parseNum();
            fail("unexpected character");
            assert(0);
        }
    }

    void expectWord(string w)
    {
        if (pos + w.length > src.length || src[pos .. pos + w.length] != w)
            fail("invalid literal");
        pos += w.length;
    }

    Value parseNum()
    {
        immutable st = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')
                ++pos;
            else
                break;
        }
        auto t = src[st .. pos];
        if (!isJsonNumber(t))
            fail("invalid number");
        return mkNum(parseNumber(t));
    }

    Value parseArray(int depth)
    {
        ++pos;
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            ++pos;
            return mkArr(null);
        }
        immutable base = vsp;
        for (;;)
        {
            skipWs();
            pushV(parseValue(depth + 1));
            skipWs();
            if (pos >= src.length)
                fail("unterminated array");
            immutable c = src[pos++];
            if (c == ',')
                continue;
            if (c == ']')
                break;
            fail("expected ',' or ']'");
        }
        auto arr = vstack[base .. vsp].dup;
        vsp = base;
        return mkArr(arr);
    }

    Value parseObject(int depth)
    {
        ++pos;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            ++pos;
            return mkObj(new Obj(0));
        }
        immutable base = esp;
        for (;;)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                fail("expected object key");
            auto key = parseString();
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                fail("expected ':'");
            ++pos;
            skipWs();
            auto v = parseValue(depth + 1);
            pushE(Entry(key, v));
            skipWs();
            if (pos >= src.length)
                fail("unterminated object");
            immutable c = src[pos++];
            if (c == ',')
                continue;
            if (c == '}')
                break;
            fail("expected ',' or '}'");
        }
        auto ents = estack[base .. esp].dup;
        esp = base;
        // Keys are distinct per the input contract; fall back to the checked
        // path if the document repeats one (last value wins).
        if (ents.length > 1 && hasDuplicate(ents))
        {
            auto o = new Obj(ents.length);
            foreach (e; ents)
                o.set(e.key, e.val);
            return mkObj(o);
        }
        return mkObj(Obj.exact(ents));
    }

    static bool hasDuplicate(Entry[] ents)
    {
        auto probe = new Obj(ents.length);
        foreach (e; ents)
        {
            if (probe.find(e.key) >= 0)
                return true;
            probe.append(e.key, Value.init);
        }
        return false;
    }

    /// Parse a string token starting at the opening quote.
    string parseString()
    {
        ++pos; // opening quote
        immutable st = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                auto s = src[st .. pos];
                ++pos;
                return s;
            }
            if (c == '\\')
                break;
            ++pos;
        }
        if (pos >= src.length)
            fail("unterminated string");
        // slow path: contains escapes
        auto buf = Buf();
        buf.put(src[st .. pos]);
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                ++pos;
                return buf.slice.idup;
            }
            if (c != '\\')
            {
                immutable run = pos;
                while (pos < src.length && src[pos] != '"' && src[pos] != '\\')
                    ++pos;
                buf.put(src[run .. pos]);
                continue;
            }
            ++pos;
            if (pos >= src.length)
                break;
            immutable e = src[pos++];
            switch (e)
            {
            case '"': buf.put('"'); break;
            case '\\': buf.put('\\'); break;
            case '/': buf.put('/'); break;
            case 'b': buf.put('\b'); break;
            case 'f': buf.put('\f'); break;
            case 'n': buf.put('\n'); break;
            case 'r': buf.put('\r'); break;
            case 't': buf.put('\t'); break;
            case 'u':
                {
                    uint cp = hex4();
                    if (cp >= 0xD800 && cp <= 0xDBFF && pos + 1 < src.length
                            && src[pos] == '\\' && src[pos + 1] == 'u')
                    {
                        immutable save = pos;
                        pos += 2;
                        immutable lo = hex4();
                        if (lo >= 0xDC00 && lo <= 0xDFFF)
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        else
                            pos = save;
                    }
                    putUtf8(buf, cp);
                    break;
                }
            default:
                fail("invalid escape");
            }
        }
        fail("unterminated string");
        assert(0);
    }

    uint hex4()
    {
        if (pos + 4 > src.length)
            fail("bad \\u escape");
        uint v = 0;
        foreach (i; 0 .. 4)
        {
            immutable c = src[pos + i];
            uint d;
            if (c >= '0' && c <= '9')
                d = c - '0';
            else if (c >= 'a' && c <= 'f')
                d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                d = c - 'A' + 10;
            else
                fail("bad \\u escape");
            v = v * 16 + d;
        }
        pos += 4;
        return v;
    }
}

/// Append the UTF-8 encoding of code point `cp`.
void putUtf8(ref Buf b, uint cp) pure nothrow
{
    if (cp < 0x80)
        b.put(cast(char) cp);
    else if (cp < 0x800)
    {
        b.put(cast(char)(0xC0 | (cp >> 6)));
        b.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        b.put(cast(char)(0xE0 | (cp >> 12)));
        b.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        b.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        b.put(cast(char)(0xF0 | (cp >> 18)));
        b.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        b.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        b.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

private immutable string hexDigits = "0123456789abcdef";

/// Append `s` as a JSON string literal (with quotes).
void writeString(ref Buf b, string s) pure nothrow @trusted
{
    b.reserve(s.length + 2);
    b.put('"');
    size_t run = 0;
    foreach (i; 0 .. s.length)
    {
        immutable c = cast(ubyte) s[i];
        if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7f)
            continue;
        if (i > run)
            b.put(s[run .. i]);
        run = i + 1;
        switch (c)
        {
        case '"': b.put("\\\""); break;
        case '\\': b.put("\\\\"); break;
        case '\b': b.put("\\b"); break;
        case '\f': b.put("\\f"); break;
        case '\n': b.put("\\n"); break;
        case '\r': b.put("\\r"); break;
        case '\t': b.put("\\t"); break;
        default:
            b.put("\\u00");
            b.put(hexDigits[c >> 4]);
            b.put(hexDigits[c & 15]);
        }
    }
    if (s.length > run)
        b.put(s[run .. $]);
    b.put('"');
}

/// Append the compact JSON text of `v`.
void writeJson(ref Buf b, Value v) nothrow @trusted
{
    final switch (v.tag)
    {
    case Tag.null_:
        b.put("null");
        break;
    case Tag.false_:
        b.put("false");
        break;
    case Tag.true_:
        b.put("true");
        break;
    case Tag.number:
        putNumber(b, v.num_);
        break;
    case Tag.string_:
        writeString(b, v.str);
        break;
    case Tag.array:
        b.put('[');
        foreach (i, e; v.arr)
        {
            if (i)
                b.put(',');
            writeJson(b, e);
        }
        b.put(']');
        break;
    case Tag.object:
        b.put('{');
        foreach (i, e; v.op.entries)
        {
            if (i)
                b.put(',');
            writeString(b, e.key);
            b.put(':');
            writeJson(b, e.val);
        }
        b.put('}');
        break;
    }
}

/// The compact JSON text of `v` as a new string.
string toJson(Value v)
{
    Buf b;
    writeJson(b, v);
    return b.slice.idup;
}

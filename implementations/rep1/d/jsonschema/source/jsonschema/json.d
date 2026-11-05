/**
 * A JSON value tree, parser, equality and printer.
 *
 * Numbers are kept exact (see $(MREF jsonschema.number)). Objects keep their
 * members in document order, so every member has a stable position; larger
 * objects also carry a hash index for key lookup.
 */
module jsonschema.json;

import std.array : appender;
import std.utf : encode;

import jsonschema.number;

/// The six JSON types.
enum Kind : ubyte
{
    null_,
    boolean,
    number,
    string,
    array,
    object
}

/// Thrown when JSON text is malformed.
class JsonException : Exception
{
    /// Byte offset of the error in the input.
    size_t offset;

    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__)
    {
        import std.conv : to;

        super(msg ~ " at offset " ~ offset.to!string, file, line);
        this.offset = offset;
    }
}

/// One member of a JSON object.
struct Member
{
    string key;
    Value value;
}

/// The members of a JSON object, in document order.
struct JsonObject
{
    /// Objects with more members than this get a hash index.
    enum indexThreshold = 8;

    Member[] members;
    private size_t[string] index;

    /// Builds the object from its members (the slice is adopted, not copied).
    this(Member[] members)
    {
        this.members = members;
        if (members.length > indexThreshold)
        {
            foreach (i, ref m; members)
                index[m.key] = i;
        }
    }

    /// Number of members.
    size_t length() const
    {
        return members.length;
    }

    /// The value stored under `key`, or null.
    inout(Value)* find(string key) inout
    {
        if (members.length > indexThreshold)
        {
            if (auto p = key in index)
                return &members[*p].value;
            return null;
        }
        foreach (ref m; members)
            if (m.key == key)
                return &m.value;
        return null;
    }
}

/// A JSON value.
struct Value
{
    /// The type of the value.
    Kind kind;

    private union Payload
    {
        bool b;
        Number n;
        string s;
        Value[] a;
        JsonObject* o;
    }

    private Payload p;

    /// The `null` value.
    static Value makeNull()
    {
        return Value.init;
    }

    /// A boolean value.
    static Value makeBool(bool b)
    {
        Value v;
        v.kind = Kind.boolean;
        v.p.b = b;
        return v;
    }

    /// A number value.
    static Value makeNumber(Number n)
    {
        Value v;
        v.kind = Kind.number;
        v.p.n = n;
        return v;
    }

    /// A string value.
    static Value makeString(string s)
    {
        Value v;
        v.kind = Kind.string;
        v.p.s = s;
        return v;
    }

    /// An array value (the slice is adopted).
    static Value makeArray(Value[] a)
    {
        Value v;
        v.kind = Kind.array;
        v.p.a = a;
        return v;
    }

    /// An object value (the members are adopted).
    static Value makeObject(Member[] members)
    {
        Value v;
        v.kind = Kind.object;
        v.p.o = new JsonObject(members);
        return v;
    }

    /// Kind predicates.
    bool isNull() const
    {
        return kind == Kind.null_;
    }
    /// ditto
    bool isBool() const
    {
        return kind == Kind.boolean;
    }
    /// ditto
    bool isNumber() const
    {
        return kind == Kind.number;
    }
    /// ditto
    bool isString() const
    {
        return kind == Kind.string;
    }
    /// ditto
    bool isArray() const
    {
        return kind == Kind.array;
    }
    /// ditto
    bool isObject() const
    {
        return kind == Kind.object;
    }

    /// The boolean payload; only valid for booleans.
    bool boolean() const
    {
        assert(kind == Kind.boolean);
        return p.b;
    }

    /// The number payload; only valid for numbers.
    ref const(Number) number() const return
    {
        assert(kind == Kind.number);
        return p.n;
    }

    /// The string payload; only valid for strings.
    string str() const
    {
        assert(kind == Kind.string);
        return p.s;
    }

    /// The array elements; only valid for arrays.
    inout(Value)[] array() inout
    {
        assert(kind == Kind.array);
        return p.a;
    }

    /// The object payload; only valid for objects.
    inout(JsonObject)* object() inout
    {
        assert(kind == Kind.object);
        return p.o;
    }

    /// Member lookup that is null for non-objects and missing keys.
    inout(Value)* opBinaryRight(string op : "in")(string key) inout
    {
        if (kind != Kind.object)
            return null;
        return p.o.find(key);
    }
}

/// JSON equality (section 3.4 of the specification): structural, numbers by value.
bool jsonEqual()(auto ref const Value a, auto ref const Value b)
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case Kind.null_:
        return true;
    case Kind.boolean:
        return a.boolean == b.boolean;
    case Kind.number:
        return a.number == b.number;
    case Kind.string:
        return a.str == b.str;
    case Kind.array:
        auto x = a.array, y = b.array;
        if (x.length != y.length)
            return false;
        foreach (i; 0 .. x.length)
            if (!jsonEqual(x[i], y[i]))
                return false;
        return true;
    case Kind.object:
        auto x = a.object, y = b.object;
        if (x.length != y.length)
            return false;
        foreach (ref m; x.members)
        {
            auto o = y.find(m.key);
            if (o is null || !jsonEqual(m.value, *o))
                return false;
        }
        return true;
    }
}

/// A hash consistent with $(LREF jsonEqual).
size_t jsonHash()(auto ref const Value v)
{
    final switch (v.kind)
    {
    case Kind.null_:
        return 0x1234567;
    case Kind.boolean:
        return v.boolean ? 0x2345678 : 0x3456789;
    case Kind.number:
        return v.number.toHash();
    case Kind.string:
        return hashOf(v.str);
    case Kind.array:
        size_t h = 0x4567890 + v.array.length;
        foreach (ref e; v.array)
            h = h * 1000003 + jsonHash(e);
        return h;
    case Kind.object:
        size_t h = 0x5678901 + v.object.length;
        foreach (ref m; v.object.members)
            h += hashOf(m.key) * 31 ^ jsonHash(m.value) * 17;
        return h;
    }
}

/// Number of code points in a UTF-8 string (counts non-continuation bytes).
size_t codePointLength(const(char)[] s) pure nothrow @nogc
{
    size_t n = 0;
    foreach (c; cast(const(ubyte)[]) s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}

/// Parses a JSON document. Throws $(LREF JsonException) on malformed input.
Value parseJson(string text)
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
    string src;
    size_t pos;
    Value[] vstack;
    Member[] mstack;

    this(string s)
    {
        src = s;
    }

    void skipWs()
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

    Value parseValue()
    {
        if (pos >= src.length)
            throw new JsonException("unexpected end of input", pos);
        switch (src[pos])
        {
        case '{':
            return parseObject();
        case '[':
            return parseArray();
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
            return parseNumber();
        }
    }

    void expectWord(string w)
    {
        if (pos + w.length > src.length || src[pos .. pos + w.length] != w)
            throw new JsonException("invalid literal", pos);
        pos += w.length;
    }

    Value parseNumber()
    {
        immutable start = pos;
        if (pos < src.length && src[pos] == '-')
            pos++;
        immutable intStart = pos;
        while (pos < src.length && isDigit(src[pos]))
            pos++;
        if (pos == intStart)
            throw new JsonException("invalid value", start);
        if (src[intStart] == '0' && pos - intStart > 1)
            throw new JsonException("leading zero", start);
        if (pos < src.length && src[pos] == '.')
        {
            pos++;
            immutable fs = pos;
            while (pos < src.length && isDigit(src[pos]))
                pos++;
            if (pos == fs)
                throw new JsonException("digits expected after decimal point", pos);
        }
        if (pos < src.length && (src[pos] == 'e' || src[pos] == 'E'))
        {
            pos++;
            if (pos < src.length && (src[pos] == '+' || src[pos] == '-'))
                pos++;
            immutable es = pos;
            while (pos < src.length && isDigit(src[pos]))
                pos++;
            if (pos == es)
                throw new JsonException("digits expected in exponent", pos);
        }
        return Value.makeNumber(Number.fromLiteral(src[start .. pos]));
    }

    static bool isDigit(char c)
    {
        return c >= '0' && c <= '9';
    }

    Value parseArray()
    {
        pos++;
        immutable base = vstack.length;
        skipWs();
        if (pos < src.length && src[pos] == ']')
        {
            pos++;
            return Value.makeArray(null);
        }
        for (;;)
        {
            skipWs();
            auto v = parseValue();
            vstack ~= v;
            skipWs();
            if (pos >= src.length)
                throw new JsonException("unterminated array", pos);
            if (src[pos] == ',')
            {
                pos++;
                continue;
            }
            if (src[pos] == ']')
            {
                pos++;
                break;
            }
            throw new JsonException("expected ',' or ']'", pos);
        }
        auto arr = vstack[base .. $].dup;
        vstack.length = base;
        vstack.assumeSafeAppend();
        return Value.makeArray(arr);
    }

    Value parseObject()
    {
        pos++;
        immutable base = mstack.length;
        skipWs();
        if (pos < src.length && src[pos] == '}')
        {
            pos++;
            return Value.makeObject(null);
        }
        for (;;)
        {
            skipWs();
            if (pos >= src.length || src[pos] != '"')
                throw new JsonException("expected object key", pos);
            auto key = parseString();
            skipWs();
            if (pos >= src.length || src[pos] != ':')
                throw new JsonException("expected ':'", pos);
            pos++;
            skipWs();
            auto v = parseValue();
            mstack ~= Member(key, v);
            skipWs();
            if (pos >= src.length)
                throw new JsonException("unterminated object", pos);
            if (src[pos] == ',')
            {
                pos++;
                continue;
            }
            if (src[pos] == '}')
            {
                pos++;
                break;
            }
            throw new JsonException("expected ',' or '}'", pos);
        }
        auto mem = mstack[base .. $].dup;
        mstack.length = base;
        mstack.assumeSafeAppend();
        return Value.makeObject(mem);
    }

    uint parseHex4()
    {
        if (pos + 4 > src.length)
            throw new JsonException("bad \\u escape", pos);
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
                throw new JsonException("bad \\u escape", pos);
            v = v * 16 + d;
        }
        pos += 4;
        return v;
    }

    string parseString()
    {
        pos++; // opening quote
        immutable start = pos;
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                auto r = src[start .. pos];
                pos++;
                return r;
            }
            if (c == '\\')
                break;
            if (c < 0x20)
                throw new JsonException("control character in string", pos);
            pos++;
        }
        auto app = appender!string();
        app.put(src[start .. pos]);
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '"')
            {
                pos++;
                return app.data;
            }
            if (c < 0x20)
                throw new JsonException("control character in string", pos);
            if (c != '\\')
            {
                app.put(c);
                pos++;
                continue;
            }
            pos++;
            if (pos >= src.length)
                break;
            immutable esc = src[pos++];
            switch (esc)
            {
            case '"':
                app.put('"');
                break;
            case '\\':
                app.put('\\');
                break;
            case '/':
                app.put('/');
                break;
            case 'b':
                app.put('\b');
                break;
            case 'f':
                app.put('\f');
                break;
            case 'n':
                app.put('\n');
                break;
            case 'r':
                app.put('\r');
                break;
            case 't':
                app.put('\t');
                break;
            case 'u':
                {
                    uint cp = parseHex4();
                    if (cp >= 0xD800 && cp < 0xDC00 && pos + 1 < src.length
                            && src[pos] == '\\' && src[pos + 1] == 'u')
                    {
                        immutable save = pos;
                        pos += 2;
                        immutable lo = parseHex4();
                        if (lo >= 0xDC00 && lo < 0xE000)
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        else
                            pos = save;
                    }
                    if (cp >= 0xD800 && cp < 0xE000)
                        cp = 0xFFFD; // lone surrogate: cannot occur in valid input
                    char[4] buf;
                    immutable n = encode(buf, cast(dchar) cp);
                    app.put(buf[0 .. n]);
                    break;
                }
            default:
                throw new JsonException("invalid escape", pos - 1);
            }
        }
        throw new JsonException("unterminated string", pos);
    }
}

/// Serialises a value as compact JSON text (numbers in canonical `<mantissa>e<exp>` form).
string toJson()(auto ref const Value v)
{
    auto app = appender!string();
    writeJson(app, v);
    return app.data;
}

private void writeJsonString(R)(ref R app, string s)
{
    app.put('"');
    foreach (char c; s)
    {
        switch (c)
        {
        case '"':
            app.put(`\"`);
            break;
        case '\\':
            app.put(`\\`);
            break;
        case '\n':
            app.put(`\n`);
            break;
        case '\r':
            app.put(`\r`);
            break;
        case '\t':
            app.put(`\t`);
            break;
        default:
            if (c < 0x20)
            {
                import std.format : format;

                app.put(format!`\u%04x`(cast(uint) c));
            }
            else
                app.put(c);
        }
    }
    app.put('"');
}

private void writeJson(R)(ref R app, ref const Value v)
{
    final switch (v.kind)
    {
    case Kind.null_:
        app.put("null");
        break;
    case Kind.boolean:
        app.put(v.boolean ? "true" : "false");
        break;
    case Kind.number:
        app.put(v.number.toString());
        break;
    case Kind.string:
        writeJsonString(app, v.str);
        break;
    case Kind.array:
        app.put('[');
        foreach (i, ref e; v.array)
        {
            if (i)
                app.put(',');
            writeJson(app, e);
        }
        app.put(']');
        break;
    case Kind.object:
        app.put('{');
        foreach (i, ref m; v.object.members)
        {
            if (i)
                app.put(',');
            writeJsonString(app, m.key);
            app.put(':');
            writeJson(app, m.value);
        }
        app.put('}');
        break;
    }
}

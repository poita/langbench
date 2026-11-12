/// The document value model (SPEC §4): construction, serialisation,
/// deserialisation, deep comparison, canonical rendering and field paths.
module tessera.value;

import std.array : Appender;

import tessera.bytes;
import tessera.errors;

/// Maximum nesting depth of a document (SPEC §4.1).
enum MAX_DEPTH = 32;
/// Maximum serialised document length in bytes.
enum MAX_DOC = 65_536;

/// The six value kinds, in type-rank order (SPEC §4).
enum Kind : ubyte
{
    null_,
    bool_,
    int_,
    string_,
    list,
    object,
}

/// One named member of an object value.
struct Field
{
    string name;
    Value value;
}

/// A document value. Objects keep their fields sorted by name (byte-wise),
/// so equal objects always have identical layouts.
struct Value
{
    /// Which of the six kinds this is.
    Kind kind;
    /// The integer, or 0/1 for a bool.
    long num;
    /// The UTF-8 bytes of a string.
    string str;
    /// Elements of a list.
    Value[] items;
    /// Fields of an object, ascending by name.
    Field[] fields;

    /// The `null` value.
    static Value nul() @safe pure nothrow
    {
        return Value(Kind.null_);
    }

    /// A boolean.
    static Value boolean(bool b) @safe pure nothrow
    {
        Value v;
        v.kind = Kind.bool_;
        v.num = b ? 1 : 0;
        return v;
    }

    /// A signed 64-bit integer.
    static Value integer(long n) @safe pure nothrow
    {
        Value v;
        v.kind = Kind.int_;
        v.num = n;
        return v;
    }

    /// A string holding the given UTF-8 text.
    static Value text(string s) @safe pure nothrow
    {
        Value v;
        v.kind = Kind.string_;
        v.str = s;
        return v;
    }

    /// A list of the given elements.
    static Value list(Value[] items) @safe pure nothrow
    {
        Value v;
        v.kind = Kind.list;
        v.items = items;
        return v;
    }

    /// An empty object.
    static Value object() @safe pure nothrow
    {
        Value v;
        v.kind = Kind.object;
        return v;
    }

    /// Insert a field into an object. Returns `false`, changing nothing, when
    /// a field of that name already exists.
    bool insertField(string name, Value value) @safe pure
    in (kind == Kind.object)
    {
        immutable i = lowerBound(name);
        if (i < fields.length && fields[i].name == name)
            return false;
        fields = fields[0 .. i] ~ Field(name, value) ~ fields[i .. $];
        return true;
    }

    /// The field called `name`, or `null` when this object has none.
    inout(Value)* field(const(char)[] name) inout @safe pure nothrow
    {
        immutable i = lowerBound(name);
        if (i < fields.length && fields[i].name == name)
            return &fields[i].value;
        return null;
    }

    /// Index of the first field whose name is not below `name`.
    private size_t lowerBound(const(char)[] name) const @safe pure nothrow
    {
        size_t lo = 0, hi = fields.length;
        while (lo < hi)
        {
            immutable mid = (lo + hi) / 2;
            if (compareBytes(asBytes(fields[mid].name), asBytes(name)) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }
}

/// Depth of a value (SPEC §4.1): 1 for scalars and empty containers.
size_t depthOf(const Value v) @safe pure nothrow
{
    size_t d = 0;
    final switch (v.kind)
    {
    case Kind.null_, Kind.bool_, Kind.int_, Kind.string_:
        return 1;
    case Kind.list:
        foreach (ref e; v.items)
        {
            immutable x = depthOf(e);
            if (x > d)
                d = x;
        }
        return d + 1;
    case Kind.object:
        foreach (ref f; v.fields)
        {
            immutable x = depthOf(f.value);
            if (x > d)
                d = x;
        }
        return d + 1;
    }
}

// ---------------------------------------------------------------- serialise

private void put32(ref Appender!(ubyte[]) o, uint n) @safe pure nothrow
{
    o.put(cast(ubyte)(n >> 24));
    o.put(cast(ubyte)(n >> 16));
    o.put(cast(ubyte)(n >> 8));
    o.put(cast(ubyte) n);
}

/// Append the stored form `ser(v)` (SPEC §4.2) to `o`.
void serialiseInto(const Value v, ref Appender!(ubyte[]) o) @safe pure nothrow
{
    final switch (v.kind)
    {
    case Kind.null_:
        o.put(cast(ubyte) 0);
        break;
    case Kind.bool_:
        o.put(cast(ubyte)(v.num ? 2 : 1));
        break;
    case Kind.int_:
        o.put(cast(ubyte) 3);
        foreach_reverse (i; 0 .. 8)
            o.put(cast(ubyte)(cast(ulong) v.num >> (8 * i)));
        break;
    case Kind.string_:
        o.put(cast(ubyte) 4);
        put32(o, cast(uint) v.str.length);
        o.put(asBytes(v.str));
        break;
    case Kind.list:
        o.put(cast(ubyte) 5);
        put32(o, cast(uint) v.items.length);
        foreach (ref e; v.items)
            serialiseInto(e, o);
        break;
    case Kind.object:
        o.put(cast(ubyte) 6);
        put32(o, cast(uint) v.fields.length);
        foreach (ref f; v.fields)
        {
            put32(o, cast(uint) f.name.length);
            o.put(asBytes(f.name));
            serialiseInto(f.value, o);
        }
        break;
    }
}

/// The stored form of a value.
ubyte[] serialise(const Value v) @safe pure nothrow
{
    Appender!(ubyte[]) o;
    serialiseInto(v, o);
    return o[];
}

/// Rebuild a value from its stored form. The input must be well formed
/// (SPEC §4.3: a database never contains anything else).
Value deserialise(const(ubyte)[] data) @safe pure
{
    size_t pos = 0;
    return readValue(data, pos);
}

private Value readValue(const(ubyte)[] d, ref size_t pos) @safe pure
{
    immutable tag = d[pos++];
    switch (tag)
    {
    case 0:
        return Value.nul();
    case 1:
        return Value.boolean(false);
    case 2:
        return Value.boolean(true);
    case 3:
        immutable n = getU64(d, pos);
        pos += 8;
        return Value.integer(cast(long) n);
    case 4:
        immutable n = getU32(d, pos);
        pos += 4;
        auto s = cast(string) d[pos .. pos + n].idup;
        pos += n;
        return Value.text(s);
    case 5:
        immutable n = getU32(d, pos);
        pos += 4;
        auto items = new Value[n];
        foreach (i; 0 .. n)
            items[i] = readValue(d, pos);
        return Value.list(items);
    case 6:
        immutable n = getU32(d, pos);
        pos += 4;
        auto fields = new Field[n];
        foreach (i; 0 .. n)
        {
            immutable len = getU32(d, pos);
            pos += 4;
            auto name = cast(string) d[pos .. pos + len].idup;
            pos += len;
            fields[i] = Field(name, readValue(d, pos));
        }
        Value v;
        v.kind = Kind.object;
        v.fields = fields;
        return v;
    default:
        throw new Exception("corrupt document");
    }
}

// ----------------------------------------------------------------- compare

/// Deep equality (SPEC §17.2). Values of different kinds are never equal.
bool deepEqual(const Value a, const Value b) @safe pure nothrow
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case Kind.null_:
        return true;
    case Kind.bool_, Kind.int_:
        return a.num == b.num;
    case Kind.string_:
        return a.str == b.str;
    case Kind.list:
        if (a.items.length != b.items.length)
            return false;
        foreach (i; 0 .. a.items.length)
            if (!deepEqual(a.items[i], b.items[i]))
                return false;
        return true;
    case Kind.object:
        if (a.fields.length != b.fields.length)
            return false;
        foreach (i; 0 .. a.fields.length)
        {
            if (a.fields[i].name != b.fields[i].name
                || !deepEqual(a.fields[i].value, b.fields[i].value))
                return false;
        }
        return true;
    }
}

/// Three-way comparison of two scalars of the same kind (null, bool, int,
/// string). Lists and objects are not ordered; callers exclude them.
int compareScalars(const Value a, const Value b) @safe pure nothrow
in (a.kind == b.kind && a.kind <= Kind.string_)
{
    final switch (a.kind)
    {
    case Kind.null_:
        return 0;
    case Kind.bool_, Kind.int_:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case Kind.string_:
        return compareBytes(asBytes(a.str), asBytes(b.str));
    case Kind.list, Kind.object:
        assert(0);
    }
}

// ------------------------------------------------------------------ render

private immutable hexDigits = "0123456789abcdef";

/// Render a string with the escaping of SPEC §4.5, including the quotes.
void renderString(const(char)[] s, ref Appender!string o) @safe pure nothrow
{
    o.put('"');
    foreach (char c; s)
    {
        switch (c)
        {
        case '"':
            o.put(`\"`);
            break;
        case '\\':
            o.put(`\\`);
            break;
        case '\b':
            o.put(`\b`);
            break;
        case '\t':
            o.put(`\t`);
            break;
        case '\n':
            o.put(`\n`);
            break;
        case '\f':
            o.put(`\f`);
            break;
        case '\r':
            o.put(`\r`);
            break;
        default:
            if (c < 0x20 || c == 0x7F)
            {
                o.put(`\u00`);
                o.put(hexDigits[c >> 4]);
                o.put(hexDigits[c & 15]);
            }
            else
                o.put(c);
        }
    }
    o.put('"');
}

/// Render a value on one line with no whitespace (SPEC §4.4).
void render(const Value v, ref Appender!string o) @safe pure nothrow
{
    import std.conv : to;

    final switch (v.kind)
    {
    case Kind.null_:
        o.put("null");
        break;
    case Kind.bool_:
        o.put(v.num ? "true" : "false");
        break;
    case Kind.int_:
        o.put(v.num.to!string);
        break;
    case Kind.string_:
        renderString(v.str, o);
        break;
    case Kind.list:
        o.put('[');
        foreach (i, ref e; v.items)
        {
            if (i)
                o.put(',');
            render(e, o);
        }
        o.put(']');
        break;
    case Kind.object:
        o.put('{');
        foreach (i, ref f; v.fields)
        {
            if (i)
                o.put(',');
            renderString(f.name, o);
            o.put(':');
            render(f.value, o);
        }
        o.put('}');
        break;
    }
}

/// Render a value to a new string.
string renderToString(const Value v) @safe pure nothrow
{
    Appender!string o;
    render(v, o);
    return o[];
}

// ------------------------------------------------------------------- paths

/// Resolve a field path against a document (SPEC §6.4). Returns `null` when
/// the path is missing. Lists are never traversed.
inout(Value)* resolvePath(return ref inout Value doc, const(string)[] segments) @trusted pure nothrow
{
    inout(Value)* cur = &doc;
    foreach (seg; segments)
    {
        if (cur.kind != Kind.object)
            return null;
        cur = cur.field(seg);
        if (cur is null)
            return null;
    }
    return cur;
}

/// Set the value at `segments` (`update`, SPEC §18.3): missing intermediate
/// fields are created as empty objects. Throws `notObject` when the document
/// or a value reached before the last segment exists and is not an object.
void setPath(ref Value doc, const(string)[] segments, Value value) @trusted pure
in (segments.length > 0)
{
    Value* cur = &doc;
    foreach (i, seg; segments)
    {
        if (cur.kind != Kind.object)
            fail(ErrorKind.notObject);
        if (i + 1 == segments.length)
        {
            if (auto f = cur.field(seg))
                *f = value;
            else
                cur.insertField(seg, value);
            return;
        }
        auto next = cur.field(seg);
        if (next is null)
        {
            cur.insertField(seg, Value.object());
            next = cur.field(seg);
        }
        cur = next;
    }
}

/// Remove the field at `segments` (`unset`, SPEC §18.3). Throws `notObject`
/// when a value on the way is not an object and `noField` when a field is
/// missing; the first failure along the path decides.
void unsetPath(ref Value doc, const(string)[] segments) @trusted pure
in (segments.length > 0)
{
    Value* cur = &doc;
    foreach (i, seg; segments)
    {
        if (cur.kind != Kind.object)
            fail(ErrorKind.notObject);
        auto next = cur.field(seg);
        if (next is null)
            fail(ErrorKind.noField);
        if (i + 1 == segments.length)
        {
            size_t at = 0;
            while (cur.fields[at].name != seg)
                at++;
            cur.fields = cur.fields[0 .. at] ~ cur.fields[at + 1 .. $];
            return;
        }
        cur = next;
    }
}

@safe pure unittest
{
    // SPEC §4.2 worked serialisations
    assert(serialise(Value.integer(1)) == [3, 0, 0, 0, 0, 0, 0, 0, 1]);
    assert(serialise(Value.integer(-1)) == [3, 255, 255, 255, 255, 255, 255, 255, 255]);
    assert(serialise(Value.text("ada")) == [4, 0, 0, 0, 3, 'a', 'd', 'a']);

    auto o = Value.object();
    assert(o.insertField("name", Value.text("ada")));
    assert(o.insertField("age", Value.integer(36)));
    assert(o.insertField("ok", Value.boolean(true)));
    assert(!o.insertField("age", Value.integer(1)));
    assert(serialise(o).length == 44);
    assert(renderToString(o) == `{"age":36,"name":"ada","ok":true}`);
    assert(deepEqual(deserialise(serialise(o)), o));
    assert(depthOf(o) == 2);
}

@safe pure unittest
{
    auto l = Value.list([Value.integer(1), Value.text("x"), Value.nul()]);
    assert(serialise(l).length == 21);
    assert(renderToString(l) == `[1,"x",null]`);
    assert(renderToString(Value.text("a\"b\u007f\u0001/é")) == "\"a\\\"b\\u007f\\u0001/é\"");
    assert(renderToString(Value.integer(long.min)) == "-9223372036854775808");
    assert(renderToString(Value.object()) == "{}");
}

@safe pure unittest
{
    auto doc = Value.object();
    setPath(doc, ["a", "b"], Value.integer(1));
    assert(renderToString(doc) == `{"a":{"b":1}}`);
    assert(resolvePath(doc, ["a", "b"]) !is null);
    assert(resolvePath(doc, ["a", "c"]) is null);
    assert(resolvePath(doc, ["a", "b", "c"]) is null);
    unsetPath(doc, ["a", "b"]);
    assert(renderToString(doc) == `{"a":{}}`);

    bool threw;
    try
        setPath(doc, ["a", "x", "y"], Value.integer(1));
    catch (TesseraError e)
        assert(false);
    try
    {
        auto d2 = Value.integer(1);
        setPath(d2, ["a"], Value.nul());
    }
    catch (TesseraError e)
    {
        threw = e.kind == ErrorKind.notObject;
    }
    assert(threw);
}

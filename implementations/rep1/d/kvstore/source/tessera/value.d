/// The document value model: construction, serialisation, comparison and
/// field-path access.
module tessera.value;

import tessera.bytes;
import tessera.constants;

/// The six value kinds, in type-rank order.
enum Kind : ubyte
{
    null_,
    boolean,
    integer,
    string_,
    list,
    object,
}

/// A document value. Objects keep their fields sorted by name (byte-wise),
/// so equal objects have identical representations.
struct Value
{
    /// The kind of value.
    Kind kind;
    /// The boolean (0/1) or integer payload.
    long num;
    /// The string payload (UTF-8 bytes).
    string str;
    /// List elements, or object field values (parallel to `names`).
    Value[] items;
    /// Object field names, ascending byte-wise and distinct.
    string[] names;

    /// The `null` value.
    static Value nullValue() pure nothrow @safe { return Value(Kind.null_); }

    /// A boolean.
    static Value boolean(bool b) pure nothrow @safe
    {
        Value v;
        v.kind = Kind.boolean;
        v.num = b ? 1 : 0;
        return v;
    }

    /// A signed 64-bit integer.
    static Value integer(long n) pure nothrow @safe
    {
        Value v;
        v.kind = Kind.integer;
        v.num = n;
        return v;
    }

    /// A string (UTF-8).
    static Value string_(string s) pure nothrow @safe
    {
        Value v;
        v.kind = Kind.string_;
        v.str = s;
        return v;
    }

    /// A list.
    static Value list(Value[] elems) pure nothrow @safe
    {
        Value v;
        v.kind = Kind.list;
        v.items = elems;
        return v;
    }

    /// An object from parallel arrays of names and values. The names must be
    /// distinct; they need not be sorted.
    static Value object(string[] fieldNames, Value[] values) pure @safe
    {
        assert(fieldNames.length == values.length);
        Value v;
        v.kind = Kind.object;
        if (fieldNames.length == 0)
            return v;
        auto order = new size_t[fieldNames.length];
        foreach (i, ref o; order)
            o = i;
        sortIndices(order, fieldNames);
        v.names = new string[fieldNames.length];
        v.items = new Value[fieldNames.length];
        foreach (i, o; order)
        {
            v.names[i] = fieldNames[o];
            v.items[i] = values[o];
        }
        return v;
    }

    /// An object from a name→value associative array.
    static Value object(Value[string] fields) pure @safe
    {
        string[] ns;
        Value[] vs;
        foreach (k, val; fields)
        {
            ns ~= k;
            vs ~= val;
        }
        return object(ns, vs);
    }

    /// True for `null`.
    bool isNull() const pure nothrow @nogc @safe { return kind == Kind.null_; }
}

private void sortIndices(size_t[] order, const string[] keys) pure @safe
{
    import std.algorithm.sorting : sort;

    order.sort!((a, b) => keys[a] < keys[b]);
}

/// Index of field `name` in an object's sorted names, or -1.
ptrdiff_t fieldIndex(ref Value obj, const(char)[] name) pure nothrow @nogc @safe
{
    size_t lo = 0, hi = obj.names.length;
    while (lo < hi)
    {
        immutable mid = (lo + hi) / 2;
        immutable c = compareBytes(asBytes(obj.names[mid]), asBytes(name));
        if (c == 0)
            return mid;
        if (c < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return -1;
}

/// The depth of a value (1 for scalars and empty containers).
int depthOf(Value v) pure nothrow @safe
{
    if (v.kind != Kind.list && v.kind != Kind.object)
        return 1;
    int d = 0;
    foreach (ref e; v.items)
    {
        immutable ed = depthOf(e);
        if (ed > d)
            d = ed;
    }
    return d + 1;
}

// ---------------------------------------------------------------- serialise

/// Append the stored form of `v` to `out_`.
void serializeInto(ref ByteBuffer out_, Value v) pure nothrow @safe
{
    final switch (v.kind)
    {
    case Kind.null_:
        out_.put(0x00);
        break;
    case Kind.boolean:
        out_.put(v.num ? 0x02 : 0x01);
        break;
    case Kind.integer:
        out_.put(0x03);
        out_.putU64(cast(ulong) v.num);
        break;
    case Kind.string_:
        out_.put(0x04);
        out_.putU32(cast(uint) v.str.length);
        out_.putText(v.str);
        break;
    case Kind.list:
        out_.put(0x05);
        out_.putU32(cast(uint) v.items.length);
        foreach (ref e; v.items)
            serializeInto(out_, e);
        break;
    case Kind.object:
        out_.put(0x06);
        out_.putU32(cast(uint) v.items.length);
        foreach (i, ref e; v.items)
        {
            out_.putU32(cast(uint) v.names[i].length);
            out_.putText(v.names[i]);
            serializeInto(out_, e);
        }
        break;
    }
}

/// The stored form of a value.
ubyte[] serialize(Value v) pure nothrow @safe
{
    ByteBuffer b;
    serializeInto(b, v);
    return b.data.dup;
}

/// Decode a value from its stored form (the inverse of `serialize`).
Value deserialize(const(ubyte)[] bytes) pure nothrow @safe
{
    size_t pos = 0;
    return readValue(bytes, pos);
}

private Value readValue(const(ubyte)[] b, ref size_t pos) pure nothrow @safe
{
    immutable tag = b[pos++];
    switch (tag)
    {
    case 0x00:
        return Value.nullValue();
    case 0x01:
        return Value.boolean(false);
    case 0x02:
        return Value.boolean(true);
    case 0x03:
        auto n = cast(long) getU64(b, pos);
        pos += 8;
        return Value.integer(n);
    case 0x04:
        immutable len = getU32(b, pos);
        pos += 4;
        auto s = toStr(b[pos .. pos + len]);
        pos += len;
        return Value.string_(s);
    case 0x05:
        immutable cnt = getU32(b, pos);
        pos += 4;
        auto elems = new Value[cnt];
        foreach (ref e; elems)
            e = readValue(b, pos);
        return Value.list(elems);
    default: // 0x06
        immutable cnt = getU32(b, pos);
        pos += 4;
        Value v;
        v.kind = Kind.object;
        if (cnt)
        {
            v.names = new string[cnt];
            v.items = new Value[cnt];
        }
        foreach (i; 0 .. cnt)
        {
            immutable nl = getU32(b, pos);
            pos += 4;
            v.names[i] = toStr(b[pos .. pos + nl]);
            pos += nl;
            v.items[i] = readValue(b, pos);
        }
        return v;
    }
}

// ---------------------------------------------------------------- comparison

/// Deep equality (same kind and equal content).
bool valuesEqual(Value a, Value b) pure nothrow @safe
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case Kind.null_:
        return true;
    case Kind.boolean:
    case Kind.integer:
        return a.num == b.num;
    case Kind.string_:
        return a.str == b.str;
    case Kind.list:
        if (a.items.length != b.items.length)
            return false;
        foreach (i; 0 .. a.items.length)
            if (!valuesEqual(a.items[i], b.items[i]))
                return false;
        return true;
    case Kind.object:
        if (a.items.length != b.items.length)
            return false;
        foreach (i; 0 .. a.items.length)
            if (a.names[i] != b.names[i] || !valuesEqual(a.items[i], b.items[i]))
                return false;
        return true;
    }
}

/// Ordering of two scalar values of the same kind: negative, zero, positive.
/// Only meaningful for null, bool, int and string.
int compareScalars(Value a, Value b) pure nothrow @safe
{
    switch (a.kind)
    {
    case Kind.boolean:
    case Kind.integer:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case Kind.string_:
        return compareBytes(asBytes(a.str), asBytes(b.str));
    default:
        return 0;
    }
}

// ---------------------------------------------------------------- paths

/// Resolve a field path; null when it is missing. Lists are never traversed.
Value* resolvePath(return ref Value doc, const string[] segments) pure nothrow @trusted
{
    Value* cur = &doc;
    foreach (seg; segments)
    {
        if (cur.kind != Kind.object)
            return null;
        immutable i = fieldIndex(*cur, seg);
        if (i < 0)
            return null;
        cur = &cur.items[i];
    }
    return cur;
}

/// Outcome of `unsetPath`.
enum PathStatus
{
    ok,
    notObject,
    noField,
}

private size_t lowerBound(const string[] names, const(char)[] name) pure nothrow @nogc @safe
{
    size_t lo = 0, hi = names.length;
    while (lo < hi)
    {
        immutable mid = (lo + hi) / 2;
        if (compareBytes(asBytes(names[mid]), asBytes(name)) < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/// Set `segments` to `nv` inside `doc`, creating missing intermediate objects.
/// Returns false (leaving `result` unspecified) when the walk meets a value
/// that is not an object. `doc` itself is not modified.
bool setPath(Value doc, const string[] segments, Value nv, out Value result) pure nothrow @safe
{
    return setAt(doc, segments, 0, nv, result);
}

private bool setAt(Value cur, const string[] segs, size_t i, Value nv, out Value result)
    pure nothrow @safe
{
    if (cur.kind != Kind.object)
        return false;
    immutable pos = lowerBound(cur.names, segs[i]);
    immutable found = pos < cur.names.length && cur.names[pos] == segs[i];
    Value child;
    if (i + 1 == segs.length)
        child = nv;
    else
    {
        Value base = found ? cur.items[pos] : Value(Kind.object);
        if (!setAt(base, segs, i + 1, nv, child))
            return false;
    }
    result.kind = Kind.object;
    if (found)
    {
        result.names = cur.names.dup;
        result.items = cur.items.dup;
        result.items[pos] = child;
    }
    else
    {
        result.names = cur.names[0 .. pos] ~ segs[i] ~ cur.names[pos .. $];
        result.items = cur.items[0 .. pos] ~ child ~ cur.items[pos .. $];
    }
    return true;
}

/// Remove the field at `segments` from `doc`. `doc` itself is not modified.
PathStatus unsetPath(Value doc, const string[] segments, out Value result) pure nothrow @safe
{
    return unsetAt(doc, segments, 0, result);
}

private PathStatus unsetAt(Value cur, const string[] segs, size_t i, out Value result)
    pure nothrow @safe
{
    if (cur.kind != Kind.object)
        return PathStatus.notObject;
    immutable pos = lowerBound(cur.names, segs[i]);
    if (!(pos < cur.names.length && cur.names[pos] == segs[i]))
        return PathStatus.noField;
    result.kind = Kind.object;
    if (i + 1 == segs.length)
    {
        result.names = cur.names[0 .. pos] ~ cur.names[pos + 1 .. $];
        result.items = cur.items[0 .. pos] ~ cur.items[pos + 1 .. $];
        return PathStatus.ok;
    }
    Value child;
    immutable st = unsetAt(cur.items[pos], segs, i + 1, child);
    if (st != PathStatus.ok)
        return st;
    result.names = cur.names.dup;
    result.items = cur.items.dup;
    result.items[pos] = child;
    return PathStatus.ok;
}

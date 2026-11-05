/**
 * Immutable JSON value model used throughout the library.
 *
 * A `Value` is a small tagged struct (16 bytes): `null`, booleans and numbers
 * live inline, while strings, arrays and objects are references to immutable
 * heap data. Copying a `Value` therefore never copies container contents.
 *
 * Objects preserve insertion order, intern-friendly shared key strings, a lazy
 * hash index for large objects and a lazily computed (and memoised) sorted key
 * permutation used by comparison and `keys`.
 */
module jq.value;

import core.stdc.string : memcmp;
import std.algorithm.sorting : sort;

/// Kind of a `Value`. The declaration order is jq's cross-type sort order.
enum Type : ubyte
{
    null_,
    false_,
    true_,
    number,
    string,
    array,
    object,
    /// Internal marker used by evaluation to carry an error message.
    error,
}

/// Heap string (UTF-8 bytes). Shared by reference.
final class JStr
{
    /// The UTF-8 text.
    string s;
    this(string s) pure nothrow @safe @nogc { this.s = s; }
}

/// Heap array. Never mutated after it has been published as a `Value`.
final class JArr
{
    /// The elements.
    Value[] items;
    this(Value[] items) pure nothrow @safe @nogc { this.items = items; }
}

/// Insertion-ordered string-keyed map. Never mutated once published
/// (only private builders created by one operation call `set`).
final class JObj
{
    /// Keys in insertion order (shared strings).
    JStr[] keys;
    /// Values, parallel to `keys`.
    Value[] vals;

    private int[string] index;
    private bool indexed;
    private uint[] order;
    private bool ordered;

    /// Objects with at most this many keys are searched linearly.
    enum linearLimit = 16;

    this() pure nothrow @safe {}
    this(JStr[] keys, Value[] vals) pure nothrow @safe @nogc
    {
        this.keys = keys;
        this.vals = vals;
    }

    /// Number of entries.
    size_t length() const pure nothrow @safe @nogc { return keys.length; }

    private ptrdiff_t findLinear(string k) const pure nothrow @trusted @nogc
    {
        foreach (i, key; keys)
        {
            const ks = key.s;
            if (ks.length == k.length && (ks.ptr is k.ptr || memcmp(ks.ptr, k.ptr, k.length) == 0))
                return i;
        }
        return -1;
    }

    private void buildIndex() nothrow
    {
        foreach (i, key; keys)
            index[key.s] = cast(int) i;
        indexed = true;
    }

    /// Position of key `k`, or -1.
    ptrdiff_t find(string k) nothrow
    {
        if (keys.length <= linearLimit && !indexed)
            return findLinear(k);
        if (!indexed)
            buildIndex();
        if (auto p = k in index)
            return *p;
        return -1;
    }

    /// Position of key `k`, always scanning linearly (no index construction).
    ptrdiff_t findScan(string k) nothrow
    {
        if (indexed)
            return find(k);
        return findLinear(k);
    }

    /// Value for `k`, or `null` if absent.
    Value get(string k) nothrow
    {
        const i = find(k);
        return i < 0 ? Value.makeNull : vals[i];
    }

    /// True if `k` is present.
    bool has(string k) nothrow { return find(k) >= 0; }

    /// Set a key on a private builder: existing keys keep their position.
    void set(JStr k, Value v) nothrow
    {
        const i = find(k.s);
        if (i >= 0)
        {
            vals[i] = v;
            return;
        }
        append(k, v);
    }

    /// As `set`, but scans linearly unless an index already exists.
    void setScan(JStr k, Value v) nothrow
    {
        const i = findScan(k.s);
        if (i >= 0)
        {
            vals[i] = v;
            return;
        }
        append(k, v);
    }

    /// Append a key known to be absent (private builders only).
    void append(JStr k, Value v) nothrow
    {
        keys ~= k;
        vals ~= v;
        if (indexed)
            index[k.s] = cast(int)(keys.length - 1);
    }

    /// Positions of the entries sorted by key (code point order); computed once.
    const(uint)[] sortedOrder() nothrow
    {
        if (!ordered)
        {
            auto o = new uint[keys.length];
            foreach (i, ref x; o)
                x = cast(uint) i;
            auto ks = keys;
            if (o.length > 1)
                o.sort!((a, b) => ks[a].s < ks[b].s);
            order = o;
            ordered = true;
        }
        return order;
    }

    /// Shallow private copy that can be extended with `set`/`append`.
    JObj copy() nothrow
    {
        auto o = new JObj(keys.dup, vals.dup);
        return o;
    }
}

/// A JSON value (or, internally, an error marker). See the module comment.
struct Value
{
    /// The kind of value.
    Type type = Type.null_;
    union
    {
        /// Payload for `Type.number`.
        double num;
        /// Payload for `Type.string` and `Type.error` (the message).
        JStr str;
        /// Payload for `Type.array`.
        JArr arr;
        /// Payload for `Type.object`.
        JObj obj;
    }

    /// The `null` value.
    static Value makeNull() pure nothrow @trusted @nogc
    {
        Value v;
        v.type = Type.null_;
        v.num = 0;
        return v;
    }

    /// A boolean.
    static Value makeBool(bool b) pure nothrow @trusted @nogc
    {
        Value v;
        v.type = b ? Type.true_ : Type.false_;
        v.num = 0;
        return v;
    }

    /// A number.
    static Value makeNumber(double d) pure nothrow @trusted @nogc
    {
        Value v;
        v.type = Type.number;
        v.num = d;
        return v;
    }

    /// A string value from UTF-8 text.
    static Value makeString(string s) pure nothrow @trusted
    {
        Value v;
        v.type = Type.string;
        v.str = new JStr(s);
        return v;
    }

    /// A string value sharing an existing heap string.
    static Value makeString(JStr s) pure nothrow @trusted @nogc
    {
        Value v;
        v.type = Type.string;
        v.str = s;
        return v;
    }

    /// An array value (takes ownership of `items`).
    static Value makeArray(Value[] items) pure nothrow @trusted
    {
        Value v;
        v.type = Type.array;
        v.arr = new JArr(items);
        return v;
    }

    /// An object value.
    static Value makeObject(JObj o) pure nothrow @trusted @nogc
    {
        Value v;
        v.type = Type.object;
        v.obj = o;
        return v;
    }

    /// An error marker carrying a message.
    static Value makeError(string msg) pure nothrow @trusted
    {
        Value v;
        v.type = Type.error;
        v.str = new JStr(msg);
        return v;
    }

    /// jq truthiness: everything except `false` and `null`.
    bool truthy() const pure nothrow @safe @nogc { return type >= Type.true_; }

    /// True for the internal error marker.
    bool isError() const pure nothrow @safe @nogc { return type == Type.error; }

    /// The string contents (valid only for strings / errors).
    string text() const pure nothrow @trusted @nogc { return str.s; }

    /// The array elements (valid only for arrays).
    Value[] items() pure nothrow @trusted @nogc { return arr.items; }
}

/// jq's name for the type of `v` ("null", "boolean", "number", ...).
string typeName(Type t) pure nothrow @safe @nogc
{
    final switch (t)
    {
    case Type.null_: return "null";
    case Type.false_:
    case Type.true_: return "boolean";
    case Type.number: return "number";
    case Type.string: return "string";
    case Type.array: return "array";
    case Type.object: return "object";
    case Type.error: return "error";
    }
}

/// Three-way comparison of two byte strings.
int compareStrings(string a, string b) pure nothrow @trusted @nogc
{
    const n = a.length < b.length ? a.length : b.length;
    const c = n == 0 ? 0 : memcmp(a.ptr, b.ptr, n);
    if (c != 0)
        return c < 0 ? -1 : 1;
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// Total order over values (null < false < true < numbers < strings < arrays < objects).
int compare(Value a, Value b) nothrow
{
    if (a.type != b.type)
    {
        return a.type < b.type ? -1 : 1;
    }
    final switch (a.type)
    {
    case Type.null_:
    case Type.false_:
    case Type.true_:
    case Type.error:
        return 0;
    case Type.number:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case Type.string:
        if (a.str is b.str)
            return 0;
        return compareStrings(a.str.s, b.str.s);
    case Type.array:
        {
            if (a.arr is b.arr)
                return 0;
            auto x = a.arr.items, y = b.arr.items;
            const n = x.length < y.length ? x.length : y.length;
            foreach (i; 0 .. n)
            {
                const c = compare(x[i], y[i]);
                if (c != 0)
                    return c;
            }
            return x.length < y.length ? -1 : (x.length > y.length ? 1 : 0);
        }
    case Type.object:
        {
            if (a.obj is b.obj)
                return 0;
            auto oa = a.obj, ob = b.obj;
            auto sa = oa.sortedOrder, sb = ob.sortedOrder;
            const n = sa.length < sb.length ? sa.length : sb.length;
            foreach (i; 0 .. n)
            {
                const c = compareStrings(oa.keys[sa[i]].s, ob.keys[sb[i]].s);
                if (c != 0)
                    return c;
            }
            if (sa.length != sb.length)
                return sa.length < sb.length ? -1 : 1;
            foreach (i; 0 .. n)
            {
                const c = compare(oa.vals[sa[i]], ob.vals[sb[i]]);
                if (c != 0)
                    return c;
            }
            return 0;
        }
    }
}

/// Equality under the total order.
bool equals(Value a, Value b) nothrow
{
    return compare(a, b) == 0;
}

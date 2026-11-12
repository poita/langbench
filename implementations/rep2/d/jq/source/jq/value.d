/**
 * Immutable JSON values with insertion-ordered objects.
 *
 * A $(D Value) is a small tagged struct (24 bytes). Strings, arrays and
 * objects are shared by reference, never deep-copied; every operation in the
 * library returns a new value instead of mutating an existing one.
 *
 * Objects ($(D JObject)) remember insertion order, give expected O(1) key
 * lookup, and sort their keys at most once (the order is cached).
 */
module jq.value;

import std.algorithm.sorting : sort;

/// Kind of a value. The enumeration order is jq's cross-type sort order.
enum Kind : ubyte
{
    null_,
    false_,
    true_,
    number,
    string,
    array,
    object,
}

/// An insertion-ordered string-keyed map.
///
/// Treat instances as immutable once they have been wrapped in a $(D Value):
/// $(D set) and $(D replaceAt) exist for code that is still building an object.
final class JObject
{
    private string[] keys_;
    private Value[] vals_;
    private uint[] hashes_; // only maintained together with table_
    private uint[] table_; // open addressing; entry = index + 1, 0 = empty
    private uint[] order_; // cached permutation giving sorted key order
    private bool orderValid_;

    private enum smallLimit = 8;

    /// Creates an empty object, reserving room for `capacity` members.
    this(size_t capacity = 0)
    {
        if (capacity)
        {
            keys_.reserve(capacity);
            vals_.reserve(capacity);
        }
    }

    /// Number of members.
    size_t length() const @safe pure nothrow @nogc
    {
        return keys_.length;
    }

    /// Keys in insertion order.
    const(string)[] keys() const @safe pure nothrow @nogc
    {
        return keys_;
    }

    /// Values in insertion order (parallel to $(D keys)).
    inout(Value)[] values() inout @safe pure nothrow @nogc
    {
        return vals_;
    }

    /// Index of `key` in insertion order, or -1.
    ptrdiff_t find(const(char)[] key) const
    {
        if (table_.length == 0)
        {
            foreach (i, k; keys_)
                if (k.length == key.length && k == key)
                    return i;
            return -1;
        }
        immutable h = cast(uint) key.hashOf;
        immutable mask = table_.length - 1;
        for (size_t p = h & mask;; p = (p + 1) & mask)
        {
            immutable e = table_[p];
            if (e == 0)
                return -1;
            immutable i = e - 1;
            if (hashes_[i] == h && keys_[i] == key)
                return i;
        }
    }

    /// Value stored under `key`, or null if absent.
    Value* opBinaryRight(string op : "in")(const(char)[] key)
    {
        auto i = find(key);
        return i < 0 ? null : &vals_[i];
    }

    /// Sets `key` to `v`: keeps the position of an existing key, appends a new one.
    void set(string key, Value v)
    {
        auto i = find(key);
        if (i >= 0)
        {
            vals_[i] = v;
            return;
        }
        orderValid_ = false;
        keys_ ~= key;
        vals_ ~= v;
        if (table_.length != 0)
        {
            hashes_ ~= cast(uint) key.hashOf;
            if (keys_.length * 2 > table_.length)
                rebuildTable(table_.length * 2);
            else
                insertSlot(keys_.length - 1);
        }
        else if (keys_.length > smallLimit)
        {
            hashes_.length = 0;
            foreach (k; keys_)
                hashes_ ~= cast(uint) k.hashOf;
            rebuildTable(32);
        }
    }

    /// Replaces the value at insertion index `i`.
    void replaceAt(size_t i, Value v)
    {
        vals_[i] = v;
    }

    /// Shallow copy with room for `extra` more members. O(length).
    JObject dup(size_t extra = 0) const
    {
        auto o = new JObject(keys_.length + extra);
        o.keys_ ~= keys_;
        o.vals_ ~= vals_;
        if (table_.length != 0)
        {
            o.hashes_.reserve(keys_.length + extra);
            o.hashes_ ~= hashes_;
            o.table_ = table_.dup;
        }
        if (orderValid_)
        {
            o.order_ = order_.dup;
            o.orderValid_ = true;
        }
        return o;
    }

    /// Indices of the members in ascending key order (computed once, then cached).
    const(uint)[] sortedOrder()
    {
        if (!orderValid_)
        {
            auto ord = new uint[keys_.length];
            foreach (i, ref x; ord)
                x = cast(uint) i;
            auto ks = keys_;
            ord.sort!((a, b) => ks[a] < ks[b]);
            order_ = ord;
            orderValid_ = true;
        }
        return order_;
    }

    /// Keys sorted by code point.
    string[] sortedKeys()
    {
        auto ord = sortedOrder();
        auto r = new string[ord.length];
        foreach (i, o; ord)
            r[i] = keys_[o];
        return r;
    }

    private void rebuildTable(size_t size)
    {
        table_ = new uint[size];
        foreach (i; 0 .. keys_.length)
            insertSlot(i);
    }

    private void insertSlot(size_t i)
    {
        immutable mask = table_.length - 1;
        size_t p = hashes_[i] & mask;
        while (table_[p] != 0)
            p = (p + 1) & mask;
        table_[p] = cast(uint)(i + 1);
    }
}

/// A JSON value.
struct Value
{
    /// The kind of this value.
    Kind kind;

    private union
    {
        double num_;
        string str_;
        Value[] arr_;
        JObject obj_;
    }

    /// `null`.
    static Value nil() @safe pure nothrow @nogc
    {
        return Value.init;
    }

    /// `true` or `false`.
    static Value fromBool(bool b) @safe pure nothrow @nogc
    {
        Value v;
        v.kind = b ? Kind.true_ : Kind.false_;
        return v;
    }

    /// A number.
    static Value fromNumber(double d) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind = Kind.number;
        v.num_ = d;
        return v;
    }

    /// A string (UTF-8).
    static Value fromString(string s) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind = Kind.string;
        v.str_ = s;
        return v;
    }

    /// An array. The slice is shared, not copied: do not mutate it afterwards.
    static Value fromArray(Value[] a) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind = Kind.array;
        v.arr_ = a;
        return v;
    }

    /// An object. Do not mutate `o` afterwards.
    static Value fromObject(JObject o) @trusted pure nothrow @nogc
    {
        Value v;
        v.kind = Kind.object;
        v.obj_ = o;
        return v;
    }

    /// The number held. Only valid when `kind == Kind.number`.
    double num() @trusted pure nothrow @nogc
    {
        assert(kind == Kind.number);
        return num_;
    }

    /// The string held. Only valid when `kind == Kind.string`.
    string str() @trusted pure nothrow @nogc
    {
        assert(kind == Kind.string);
        return str_;
    }

    /// The elements held. Only valid when `kind == Kind.array`.
    Value[] arr() @trusted pure nothrow @nogc
    {
        assert(kind == Kind.array);
        return arr_;
    }

    /// The object held. Only valid when `kind == Kind.object`.
    JObject obj() @trusted pure nothrow @nogc
    {
        assert(kind == Kind.object);
        return obj_;
    }

    /// jq truthiness: everything except `false` and `null`.
    bool truthy() const @safe pure nothrow @nogc
    {
        return kind != Kind.null_ && kind != Kind.false_;
    }

    /// jq type name as returned by the `type` builtin.
    string typeName() const @safe pure nothrow @nogc
    {
        final switch (kind)
        {
        case Kind.null_:
            return "null";
        case Kind.false_:
        case Kind.true_:
            return "boolean";
        case Kind.number:
            return "number";
        case Kind.string:
            return "string";
        case Kind.array:
            return "array";
        case Kind.object:
            return "object";
        }
    }

    /// Equality under the total order (object key order is irrelevant).
    bool opEquals(Value other)
    {
        return compare(this, other) == 0;
    }

    /// Comparison under the total order.
    int opCmp(Value other)
    {
        return compare(this, other);
    }
}

/// Compares two values under jq's total order; returns <0, 0 or >0.
int compare(Value a, Value b)
{
    if (a.kind != b.kind)
        return a.kind < b.kind ? -1 : 1;
    final switch (a.kind)
    {
    case Kind.null_:
    case Kind.false_:
    case Kind.true_:
        return 0;
    case Kind.number:
        immutable x = a.num, y = b.num;
        return x < y ? -1 : (x > y ? 1 : 0);
    case Kind.string:
        return compareStrings(a.str, b.str);
    case Kind.array:
        auto xs = a.arr, ys = b.arr;
        immutable n = xs.length < ys.length ? xs.length : ys.length;
        foreach (i; 0 .. n)
        {
            immutable c = compare(xs[i], ys[i]);
            if (c != 0)
                return c;
        }
        return xs.length < ys.length ? -1 : (xs.length > ys.length ? 1 : 0);
    case Kind.object:
        auto oa = a.obj, ob = b.obj;
        if (oa is ob)
            return 0;
        auto sa = oa.sortedOrder, sb = ob.sortedOrder;
        immutable n = sa.length < sb.length ? sa.length : sb.length;
        foreach (i; 0 .. n)
        {
            immutable c = compareStrings(oa.keys[sa[i]], ob.keys[sb[i]]);
            if (c != 0)
                return c;
        }
        if (sa.length != sb.length)
            return sa.length < sb.length ? -1 : 1;
        foreach (i; 0 .. n)
        {
            immutable c = compare(oa.values[sa[i]], ob.values[sb[i]]);
            if (c != 0)
                return c;
        }
        return 0;
    }
}

/// Code point order, which equals byte order for UTF-8.
int compareStrings(string a, string b) @safe pure nothrow @nogc
{
    import core.stdc.string : memcmp;

    immutable n = a.length < b.length ? a.length : b.length;
    immutable c = (() @trusted => memcmp(a.ptr, b.ptr, n))();
    if (c != 0)
        return c < 0 ? -1 : 1;
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

unittest
{
    auto n = Value.fromNumber(1);
    assert(n == Value.fromNumber(1.5 - 0.5));
    assert(Value.nil < Value.fromBool(false));
    assert(Value.fromBool(false) < Value.fromBool(true));
    assert(Value.fromBool(true) < n);
    assert(n < Value.fromString(""));
    assert(Value.fromString("Z") < Value.fromString("a"));
    assert(Value.fromString("z") < Value.fromString("é"));
    assert(Value.fromString("") < Value.fromString("a"));
    assert(Value.fromString("ab") < Value.fromString("b"));
    assert(Value.fromString("zz") < Value.fromArray([]));
    assert(Value.fromArray([]) < Value.fromObject(new JObject));
}

unittest
{
    auto o = new JObject;
    foreach (i; 0 .. 100)
        o.set(i % 2 ? "k" ~ cast(char)('a' + i % 26) ~ cast(char)('a' + i / 26) : "x" ~ cast(char)('a' + i % 26) ~ cast(char)('a' + i / 26),
                Value.fromNumber(i));
    assert(o.length == 100);
    foreach (i, k; o.keys)
        assert(o.find(k) == i);
    assert(o.find("nope") < 0);
    o.set(o.keys[3], Value.fromNumber(-1));
    assert(o.length == 100 && o.values[3].num == -1);
    auto c = o.dup(1);
    c.set("new", Value.nil);
    assert(c.length == 101 && o.length == 100 && o.find("new") < 0 && c.find("new") == 100);
    auto sk = o.sortedKeys;
    assert(sk.length == 100);
    foreach (i; 1 .. sk.length)
        assert(sk[i - 1] < sk[i]);
}

unittest
{
    auto a = new JObject, b = new JObject;
    a.set("a", Value.fromNumber(1));
    a.set("b", Value.fromNumber(2));
    b.set("b", Value.fromNumber(2));
    b.set("a", Value.fromNumber(1));
    assert(Value.fromObject(a) == Value.fromObject(b));
    b.set("a", Value.fromNumber(3));
    assert(Value.fromObject(a) < Value.fromObject(b));
    auto c = new JObject;
    c.set("a", Value.fromNumber(1));
    assert(Value.fromObject(c) < Value.fromObject(a)); // fewer sorted keys sort first
}

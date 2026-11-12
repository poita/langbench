/// The immutable JSON value model: `Value`, `JObject`, ordering and equality.
module jq.value;

import core.stdc.string : memcmp;
import std.algorithm.sorting : sort;
import std.range : iota;
import std.array : array;

/// The type of a `Value`, declared in jq's type order
/// (`null < false < true < numbers < strings < arrays < objects`).
enum Kind : ubyte
{
    Null,
    False,
    True,
    Number,
    String,
    Array,
    Object,
}

/// A JSON value.
///
/// Values are immutable by convention and cheap to copy: strings, arrays and
/// objects are shared, never deep-copied. Build them with the `Value.make*`
/// factory functions; inspect them with `kind` and the accessors below.
struct Value
{
    /// Which member of the union below is active.
    Kind kind;

    union
    {
        /// The number, when `kind == Kind.Number`.
        double num;
        /// The string (UTF-8), when `kind == Kind.String`.
        string str;
        /// The elements, when `kind == Kind.Array`. Never mutate.
        Value[] arr;
        /// The object, when `kind == Kind.Object`.
        JObject obj;
    }

    /// The `null` value.
    static Value makeNull() pure nothrow @nogc @safe
    {
        Value v;
        v.kind = Kind.Null;
        return v;
    }

    /// `true` or `false`.
    static Value makeBool(bool b) pure nothrow @nogc @safe
    {
        Value v;
        v.kind = b ? Kind.True : Kind.False;
        return v;
    }

    /// A number.
    static Value makeNumber(double d) pure nothrow @nogc @safe
    {
        Value v;
        v.kind = Kind.Number;
        v.num = d;
        return v;
    }

    /// A string. The text is shared, not copied.
    static Value makeString(string s) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.String;
        v.str = s;
        return v;
    }

    /// An array. The slice is shared, not copied: do not mutate it afterwards.
    static Value makeArray(Value[] a) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.Array;
        v.arr = a;
        return v;
    }

    /// An object.
    static Value makeObject(JObject o) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.Object;
        v.obj = o;
        return v;
    }

    /// jq truthiness: everything except `false` and `null` is true.
    bool truthy() const pure nothrow @nogc @safe
    {
        return kind != Kind.Null && kind != Kind.False;
    }

    /// The jq type name: "null", "boolean", "number", "string", "array" or "object".
    string typeName() const pure nothrow @nogc @safe
    {
        final switch (kind)
        {
        case Kind.Null:
            return "null";
        case Kind.False:
        case Kind.True:
            return "boolean";
        case Kind.Number:
            return "number";
        case Kind.String:
            return "string";
        case Kind.Array:
            return "array";
        case Kind.Object:
            return "object";
        }
    }

    /// Equality under jq's total order (object key order is irrelevant).
    bool opEquals(const Value o) const
    {
        return equals(cast() this, cast() o);
    }
}

/// An insertion-ordered string-keyed map with expected O(1) lookup.
///
/// Objects are immutable once constructed (use `ObjectBuilder` to make one).
/// The sorted key order is computed at most once and cached.
final class JObject
{
    /// Keys in insertion order. Never mutate.
    string[] keys;
    /// Values, parallel to `keys`. Never mutate.
    Value[] vals;

    private int[string] index_;
    private bool indexBuilt_;
    private Store st_; // shared append-only storage, see `appendDisjoint`
    private uint[] order_;
    private bool orderBuilt_;

    /// Objects up to this size are searched linearly.
    private enum linearLimit = 12;

    /// Takes ownership of the two parallel arrays; keys must be distinct.
    this(string[] keys, Value[] vals) pure nothrow @safe
    {
        this.keys = keys;
        this.vals = vals;
    }

    /// Number of members.
    size_t length() const pure nothrow @nogc @safe
    {
        return keys.length;
    }

    /// Position of `key` in insertion order, or -1.
    ptrdiff_t find(const(char)[] key) @trusted
    {
        immutable n = keys.length;
        if (n <= linearLimit)
        {
            foreach (i; 0 .. n)
            {
                const k = keys[i];
                if (k.length == key.length && (k.length == 0 || memcmp(k.ptr, key.ptr, k.length) == 0))
                    return i;
            }
            return -1;
        }
        if (st_ !is null)
        {
            st_.catchUp();
            if (auto p = key in st_.idx)
                return *p < n ? *p : -1;
            return -1;
        }
        if (!indexBuilt_)
        {
            foreach (i, k; keys)
                index_[k] = cast(int) i;
            indexBuilt_ = true;
        }
        if (auto p = key in index_)
            return *p;
        return -1;
    }

    /// A new object holding this object's members followed by `ks`/`vs`,
    /// none of whose keys may already be present (and which are distinct).
    ///
    /// When this object is the newest user of its backing store the new
    /// members are appended in place (older objects only ever see their own
    /// prefix), so building an object by repeated `+` costs O(|new members|)
    /// amortized rather than O(size) per step. Values stay immutable.
    JObject appendDisjoint(const(string)[] ks, const(Value)[] vs) @trusted
    {
        immutable n = keys.length, m = ks.length;
        Store st = st_;
        if (st is null || st.used != n || st.keysBuf.length < n + m)
        {
            immutable cap = (n + m) * 2 < 8 ? 8 : (n + m) * 2;
            auto nst = new Store;
            nst.keysBuf = new string[cap];
            nst.valsBuf = new Value[cap];
            nst.keysBuf[0 .. n] = keys[];
            nst.valsBuf[0 .. n] = vals[];
            nst.used = n;
            st = nst;
        }
        st.keysBuf[n .. n + m] = ks[];
        st.valsBuf[n .. n + m] = vs[];
        st.used = n + m;
        auto r = new JObject(st.keysBuf[0 .. n + m], st.valsBuf[0 .. n + m]);
        r.st_ = st;
        return r;
    }

    /// The value stored under `key`, or null if absent.
    Value* get(const(char)[] key)
    {
        immutable i = find(key);
        return i < 0 ? null : &vals[i];
    }

    /// Indices into `keys`/`vals` in ascending key order (code point order).
    /// Computed on first use, then cached.
    const(uint)[] sortedOrder() @trusted
    {
        if (!orderBuilt_)
        {
            auto ord = iota(0u, cast(uint) keys.length).array;
            auto ks = keys;
            sort!((a, b) => compareStrings(ks[a], ks[b]) < 0)(ord);
            order_ = ord;
            orderBuilt_ = true;
        }
        return order_;
    }

    /// The keys in ascending order.
    string[] sortedKeys()
    {
        auto ord = sortedOrder();
        auto r = new string[ord.length];
        foreach (i, o; ord)
            r[i] = keys[o];
        return r;
    }
}

/// Append-only backing arrays shared by a chain of objects built with
/// `JObject.appendDisjoint`, plus a key index covering all of them.
private final class Store
{
    string[] keysBuf;
    Value[] valsBuf;
    size_t used; // members written so far
    int[string] idx; // key -> position, for positions < indexed
    size_t indexed;

    void catchUp()
    {
        for (; indexed < used; ++indexed)
            idx[keysBuf[indexed]] = cast(int) indexed;
    }
}

/// Accumulates members for a new `JObject`. A repeated key keeps its first
/// position but takes the last value.
struct ObjectBuilder
{
    private string[] keys_;
    private Value[] vals_;
    private size_t n_;
    private int[string] index_;

    /// Reserves room for `n` members.
    this(size_t n)
    {
        keys_ = new string[n];
        vals_ = new Value[n];
    }

    /// Number of distinct keys so far.
    size_t length() const pure nothrow @nogc @safe
    {
        return n_;
    }

    /// Sets `key` to `v`.
    void set(string key, Value v)
    {
        if (n_ <= 12)
        {
            foreach (i; 0 .. n_)
                if (keys_[i] == key)
                {
                    vals_[i] = v;
                    return;
                }
        }
        else
        {
            if (index_ is null)
                foreach (i; 0 .. n_)
                    index_[keys_[i]] = cast(int) i;
            if (auto p = key in index_)
            {
                vals_[*p] = v;
                return;
            }
        }
        if (n_ == keys_.length)
        {
            immutable cap = n_ < 4 ? 4 : n_ * 2;
            keys_.length = cap;
            vals_.length = cap;
        }
        keys_[n_] = key;
        vals_[n_] = v;
        if (index_ !is null)
            index_[key] = cast(int) n_;
        ++n_;
    }

    /// The finished object. The builder must not be used afterwards.
    JObject build()
    {
        return new JObject(keys_[0 .. n_], vals_[0 .. n_]);
    }
}

/// Compares two strings by code point (equivalently by UTF-8 bytes).
int compareStrings(const(char)[] a, const(char)[] b) @trusted pure nothrow @nogc
{
    immutable n = a.length < b.length ? a.length : b.length;
    if (n != 0)
    {
        immutable c = memcmp(a.ptr, b.ptr, n);
        if (c != 0)
            return c < 0 ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// Compares two arrays of values lexicographically (a proper prefix sorts first).
int compareArrays(const(Value)[] a, const(Value)[] b)
{
    immutable n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
    {
        immutable c = compare(cast() a[i], cast() b[i]);
        if (c != 0)
            return c;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// jq's total order over values; returns a negative, zero or positive int.
int compare(Value a, Value b)
{
    if (a.kind != b.kind)
        return a.kind < b.kind ? -1 : 1;
    final switch (a.kind)
    {
    case Kind.Null:
    case Kind.False:
    case Kind.True:
        return 0;
    case Kind.Number:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case Kind.String:
        return compareStrings(a.str, b.str);
    case Kind.Array:
        return compareArrays(a.arr, b.arr);
    case Kind.Object:
        {
            auto x = a.obj, y = b.obj;
            if (x is y)
                return 0;
            auto ox = x.sortedOrder(), oy = y.sortedOrder();
            immutable n = ox.length < oy.length ? ox.length : oy.length;
            foreach (i; 0 .. n)
            {
                immutable c = compareStrings(x.keys[ox[i]], y.keys[oy[i]]);
                if (c != 0)
                    return c;
            }
            if (ox.length != oy.length)
                return ox.length < oy.length ? -1 : 1;
            foreach (i; 0 .. n)
            {
                immutable c = compare(x.vals[ox[i]], y.vals[oy[i]]);
                if (c != 0)
                    return c;
            }
            return 0;
        }
    }
}

/// Equality: "compares equal under jq's order".
bool equals(Value a, Value b)
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case Kind.Null:
    case Kind.False:
    case Kind.True:
        return true;
    case Kind.Number:
        return a.num == b.num;
    case Kind.String:
        return a.str == b.str;
    case Kind.Array:
        {
            if (a.arr.length != b.arr.length)
                return false;
            foreach (i; 0 .. a.arr.length)
                if (!equals(a.arr[i], b.arr[i]))
                    return false;
            return true;
        }
    case Kind.Object:
        {
            auto x = a.obj, y = b.obj;
            if (x is y)
                return true;
            if (x.length != y.length)
                return false;
            foreach (i; 0 .. x.length)
            {
                auto p = y.get(x.keys[i]);
                if (p is null || !equals(x.vals[i], *p))
                    return false;
            }
            return true;
        }
    }
}

version (unittest)
{
    private Value obj(string[] ks, Value[] vs)
    {
        return Value.makeObject(new JObject(ks, vs));
    }

    private Value num(double d)
    {
        return Value.makeNumber(d);
    }

    private Value str(string s)
    {
        return Value.makeString(s);
    }
}

unittest
{
    // type order
    Value[] ordered = [
        Value.makeNull(), Value.makeBool(false), Value.makeBool(true), num(-1), num(0),
        str(""), str("a"), str("ab"), str("b"), str("z"), str("é"),
        Value.makeArray([]), Value.makeArray([num(1)]), Value.makeArray([num(1), num(0)]),
        Value.makeArray([num(2)]), obj([], []), obj(["a"], [num(1)]), obj(["a"], [num(2)]),
        obj(["b"], [num(0)]),
    ];
    foreach (i; 0 .. ordered.length)
        foreach (j; 0 .. ordered.length)
        {
            immutable c = compare(ordered[i], ordered[j]);
            assert((c < 0) == (i < j) && (c == 0) == (i == j), "order");
        }
}

unittest
{
    // equality ignores object key order
    assert(equals(obj(["a", "b"], [num(1), num(2)]), obj(["b", "a"], [num(2), num(1)])));
    assert(!equals(obj(["a"], [num(1)]), obj(["a"], [num(2)])));
    assert(compare(obj(["a", "b"], [num(1), num(2)]), obj(["b", "a"], [num(2), num(1)])) == 0);
}

unittest
{
    ObjectBuilder b;
    b.set("a", num(1));
    b.set("b", num(2));
    b.set("a", num(3));
    auto o = b.build();
    assert(o.keys == ["a", "b"] && o.vals[0].num == 3);
    assert(o.find("b") == 1 && o.find("c") == -1);
    // large object uses the hash index
    ObjectBuilder big;
    foreach (i; 0 .. 100)
        big.set(cast(string)("k" ~ cast(char)('a' + i % 26) ~ cast(char)('a' + i / 26)), num(i));
    auto bo = big.build();
    assert(bo.length == 100 && bo.find("kba") == 1);
    assert(bo.sortedKeys()[0] == "kaa");
}

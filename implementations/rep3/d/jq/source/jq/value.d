/// The value model: a compact tagged `Value` and the insertion-ordered
/// `Obj` object type.
///
/// Scalars (null, booleans, numbers) are stored inline. Strings and arrays are
/// a (pointer, length) pair packed into the value; objects are a reference to
/// an `Obj`. Values are immutable by convention and share their children;
/// only a freshly created `Obj` (a private builder) is ever mutated.
module jq.value;

import core.stdc.string : memcmp;

/// Type tag. The declaration order is jq's type order (used by comparison).
enum Tag : ubyte
{
    null_,
    false_,
    true_,
    number,
    string_,
    array,
    object,
}

/// An object member.
struct Entry
{
    string key;
    Value val;
}

/// A JSON value (16 bytes, copied by value; heap data is shared by reference).
struct Value
{
    Tag tag = Tag.null_;
    uint len; // byte length of a string / element count of an array
    union
    {
        Value* ap; // array elements
        double num_; // number payload
        immutable(char)* sp; // string bytes
        Obj op; // object payload
    }

    /// True unless the value is `false` or `null`.
    @property bool truthy() const pure nothrow @nogc @safe
    {
        return tag > Tag.false_;
    }

    @property bool isNull() const pure nothrow @nogc @safe { return tag == Tag.null_; }
    @property bool isNumber() const pure nothrow @nogc @safe { return tag == Tag.number; }
    @property bool isString() const pure nothrow @nogc @safe { return tag == Tag.string_; }
    @property bool isArray() const pure nothrow @nogc @safe { return tag == Tag.array; }
    @property bool isObject() const pure nothrow @nogc @safe { return tag == Tag.object; }
    @property bool isBool() const pure nothrow @nogc @safe
    {
        return tag == Tag.false_ || tag == Tag.true_;
    }

    /// The number payload (valid when `isNumber`).
    @property double num() const pure nothrow @nogc @trusted { return num_; }

    /// The string payload (valid when `isString`). Shares storage.
    @property string str() pure nothrow @nogc @trusted { return sp[0 .. len]; }

    /// The array elements (valid when `isArray`). Shares storage; do not mutate.
    @property Value[] arr() pure nothrow @nogc @trusted { return ap[0 .. len]; }

    /// The object (valid when `isObject`).
    @property Obj obj() pure nothrow @nogc @trusted { return op; }
}

/// The `null` value.
Value mkNull() pure nothrow @nogc @safe
{
    return Value.init;
}

/// A boolean value.
Value mkBool(bool b) pure nothrow @nogc @safe
{
    Value v;
    v.tag = b ? Tag.true_ : Tag.false_;
    return v;
}

/// A number value.
Value mkNum(double d) pure nothrow @nogc @trusted
{
    Value v;
    v.tag = Tag.number;
    v.num_ = d;
    return v;
}

/// A string value (shares `s`).
Value mkStr(string s) pure nothrow @nogc @trusted
{
    assert(s.length <= uint.max);
    Value v;
    v.tag = Tag.string_;
    v.len = cast(uint) s.length;
    v.sp = s.ptr;
    return v;
}

/// An array value (shares `a`; the caller must not mutate it afterwards).
Value mkArr(Value[] a) pure nothrow @nogc @trusted
{
    assert(a.length <= uint.max);
    Value v;
    v.tag = Tag.array;
    v.len = cast(uint) a.length;
    v.ap = a.ptr;
    return v;
}

/// An object value.
Value mkObj(Obj o) pure nothrow @nogc @trusted
{
    Value v;
    v.tag = Tag.object;
    v.op = o;
    return v;
}

/// Three-way byte-wise string comparison (= code point order for UTF-8).
int cmpStr(string a, string b) pure nothrow @nogc @trusted
{
    size_t m = a.length < b.length ? a.length : b.length;
    int c = m ? memcmp(a.ptr, b.ptr, m) : 0;
    if (c != 0)
        return c < 0 ? -1 : 1;
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// String equality.
bool keyEq(string a, string b) pure nothrow @nogc @trusted
{
    return a.length == b.length && (a.ptr is b.ptr || memcmp(a.ptr, b.ptr, a.length) == 0);
}

private uint hashKey(string s) pure nothrow @nogc @trusted
{
    uint h = 2_166_136_261u;
    foreach (c; cast(const(ubyte)[]) s)
    {
        h ^= c;
        h *= 16_777_619u;
    }
    return h;
}

/// An insertion-ordered string-keyed map.
///
/// Entries live in a vector. Lookup scans linearly while the object is small
/// and uses a lazily built open-addressing hash index once it has more than
/// `smallLimit` keys. The code-point-sorted key order is computed on first use
/// and memoised.
final class Obj
{
    enum smallLimit = 8;

    private Entry[] data; // capacity = data.length
    private uint n; // live entries
    private uint[] table; // hash index: position + 1, 0 = empty
    private uint[] order; // memoised sorted permutation

    /// An empty object with room for `cap` entries.
    this(size_t cap = 0) pure nothrow @safe
    {
        if (cap)
            data = new Entry[cap];
    }

    /// Adopt `d` (exactly the entries; keys must be distinct).
    static Obj exact(Entry[] d) pure nothrow @safe
    {
        auto o = new Obj(0);
        o.data = d;
        o.n = cast(uint) d.length;
        return o;
    }

    /// A private copy of `src` with room for `extra` more entries.
    static Obj copyOf(Obj src, size_t extra = 0) pure nothrow @trusted
    {
        auto o = new Obj(0);
        o.data = new Entry[src.n + extra];
        o.data[0 .. src.n] = src.data[0 .. src.n];
        o.n = src.n;
        if (src.table.length >= 2 * (src.n + extra) && src.table.length)
            o.table = src.table.dup;
        return o;
    }

    /// Number of entries.
    @property size_t length() const pure nothrow @nogc @safe { return n; }

    /// The entries in insertion order. Do not mutate.
    @property Entry[] entries() pure nothrow @nogc @trusted { return data[0 .. n]; }

    /// Position of `key`, or -1.
    int find(string key) pure nothrow @trusted
    {
        if (n <= smallLimit)
        {
            foreach (i; 0 .. n)
                if (keyEq(data[i].key, key))
                    return cast(int) i;
            return -1;
        }
        if (table.length == 0)
            buildTable();
        immutable mask = cast(uint) table.length - 1;
        uint h = hashKey(key) & mask;
        for (;;)
        {
            immutable e = table[h];
            if (e == 0)
                return -1;
            if (keyEq(data[e - 1].key, key))
                return cast(int)(e - 1);
            h = (h + 1) & mask;
        }
    }

    /// The value under `key`; `found` tells whether it existed.
    Value get(string key, out bool found) pure nothrow @trusted
    {
        immutable i = find(key);
        found = i >= 0;
        return i >= 0 ? data[i].val : Value.init;
    }

    /// Set `key` to `val` (replacing in place, or appending). Only call on a
    /// private builder that has not been published yet.
    void set(string key, Value val) pure nothrow @trusted
    {
        immutable i = find(key);
        if (i >= 0)
        {
            data[i].val = val;
            return;
        }
        append(key, val);
    }

    /// Append an entry whose key is known to be absent.
    void append(string key, Value val) pure nothrow @trusted
    {
        if (n == data.length)
        {
            auto nd = new Entry[n < 4 ? 4 : n * 2];
            nd[0 .. n] = data[0 .. n];
            data = nd;
        }
        data[n] = Entry(key, val);
        ++n;
        order = null;
        if (table.length)
        {
            if (cast(size_t) n * 2 > table.length)
                table = null;
            else
                insertSlot(n - 1);
        }
    }

    /// Positions of the entries sorted by key (code point order); memoised.
    const(uint)[] sortedOrder() pure nothrow @trusted
    {
        if (order.length != n)
        {
            auto o = new uint[n];
            foreach (i; 0 .. n)
                o[i] = i;
            sortPerm(o);
            order = o;
        }
        return order;
    }

    private void sortPerm(uint[] o) pure nothrow @trusted
    {
        // Merge sort on the permutation (keys are distinct).
        if (o.length < 2)
            return;
        auto tmp = new uint[o.length];
        msort(o, tmp);
    }

    private void msort(uint[] a, uint[] tmp) pure nothrow @trusted
    {
        if (a.length <= 8)
        {
            foreach (i; 1 .. a.length)
            {
                auto x = a[i];
                size_t j = i;
                while (j > 0 && cmpStr(data[a[j - 1]].key, data[x].key) > 0)
                {
                    a[j] = a[j - 1];
                    --j;
                }
                a[j] = x;
            }
            return;
        }
        immutable mid = a.length / 2;
        msort(a[0 .. mid], tmp[0 .. mid]);
        msort(a[mid .. $], tmp[mid .. $]);
        size_t i = 0, j = mid, k = 0;
        while (i < mid && j < a.length)
            tmp[k++] = cmpStr(data[a[j]].key, data[a[i]].key) < 0 ? a[j++] : a[i++];
        while (i < mid)
            tmp[k++] = a[i++];
        while (j < a.length)
            tmp[k++] = a[j++];
        a[] = tmp[0 .. a.length];
    }

    private void buildTable() pure nothrow @trusted
    {
        size_t want = (n > data.length ? n : data.length) * 2;
        size_t sz = 16;
        while (sz < want)
            sz <<= 1;
        table = new uint[sz];
        foreach (i; 0 .. n)
            insertSlot(i);
    }

    private void insertSlot(size_t i) pure nothrow @trusted
    {
        immutable mask = cast(uint) table.length - 1;
        uint h = hashKey(data[i].key) & mask;
        while (table[h] != 0)
            h = (h + 1) & mask;
        table[h] = cast(uint)(i + 1);
    }
}

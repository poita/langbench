/**
 * Immutable JSON values and the jq total order.
 *
 * A $(LREF Value) is a 16-byte tagged union: `null`, booleans and numbers are
 * stored inline; strings, arrays and objects are references to immutable heap
 * data ($(LREF JStr), $(LREF JArray), $(LREF JObject)). Copying a `Value`
 * copies the reference, never the contents.
 *
 * Containers are never mutated once they have been handed out. The mutating
 * methods (`JObject.set`) exist only for code that is still building a
 * private container.
 */
module jq.value;

import core.stdc.string : memcmp;
import std.algorithm.sorting : sort;

/// Value types, declared in jq's type order (`null < false < true < number < string < array < object`).
enum Kind : ubyte
{
    null_,
    false_,
    true_,
    number,
    string_,
    array,
    object,
}

/// Name of a kind as reported by jq's `type` builtin.
string typeName(Kind k) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case Kind.null_:
        return "null";
    case Kind.false_:
    case Kind.true_:
        return "boolean";
    case Kind.number:
        return "number";
    case Kind.string_:
        return "string";
    case Kind.array:
        return "array";
    case Kind.object:
        return "object";
    }
}

/// 32-bit FNV-1a hash of a byte string (never 0, so 0 can mean "not computed").
uint hashBytes(const(char)[] s) pure nothrow @nogc @trusted
{
    uint h = 2166136261u;
    foreach (c; s)
        h = (h ^ cast(ubyte) c) * 16777619u;
    return h == 0 ? 1 : h;
}

/// Three-way comparison of two strings by UTF-8 bytes (= code point order).
int compareBytes(const(char)[] a, const(char)[] b) pure nothrow @nogc @trusted
{
    immutable n = a.length < b.length ? a.length : b.length;
    if (n > 0)
    {
        immutable r = memcmp(a.ptr, b.ptr, n);
        if (r != 0)
            return r < 0 ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/// Number of code points in a UTF-8 string.
size_t codePointCount(const(char)[] s) pure nothrow @nogc @trusted
{
    size_t n = 0;
    foreach (c; s)
        if ((cast(ubyte) c & 0xC0) != 0x80)
            ++n;
    return n;
}

/// Byte offset of the `cp`-th code point of `s` (`s.length` if `cp` is past the end).
size_t byteOffsetOfCodePoint(const(char)[] s, size_t cp) pure nothrow @nogc @trusted
{
    size_t i = 0;
    while (cp > 0 && i < s.length)
    {
        ++i;
        while (i < s.length && (cast(ubyte) s[i] & 0xC0) == 0x80)
            ++i;
        --cp;
    }
    return i;
}

/// An immutable, shareable string (UTF-8) with a lazily cached hash.
final class JStr
{
    /// The text.
    string s;
    private uint hash_;

    ///
    this(string s) pure nothrow @nogc @safe
    {
        this.s = s;
    }

    /// Cached FNV-1a hash of the text.
    uint hash() pure nothrow @nogc @safe
    {
        if (hash_ == 0)
            hash_ = hashBytes(s);
        return hash_;
    }

    /// True if both strings hold the same bytes.
    bool sameText(const JStr o) const pure nothrow @nogc @trusted
    {
        return this is o || (s.length == o.s.length && (s.length == 0 || memcmp(s.ptr, o.s.ptr, s.length) == 0));
    }
}

/// An immutable array of values.
final class JArray
{
    /// The elements. Treat as read-only.
    Value[] items;

    ///
    this(Value[] items) pure nothrow @nogc @safe
    {
        this.items = items;
    }
}

/// A key/value pair of an object.
struct Entry
{
    JStr key;
    Value val;
}

/**
 * An insertion-ordered string-keyed map.
 *
 * Entries are kept in a vector in insertion order. Lookups scan linearly while
 * the object is small and use an open-addressing hash index (key -> position)
 * once it has more than $(D indexThreshold) keys. The code-point-sorted key
 * order (as a permutation of entry positions) is computed lazily, at most once.
 */
final class JObject
{
    /// Objects with more keys than this get a hash index.
    enum indexThreshold = 12;

    private Entry[] store;
    private size_t count;
    private int[] table; // open addressing, -1 = empty, otherwise entry position
    private uint[] sorted; // memoised sorted-key permutation

    /// Create an empty object with room for `capacity` entries.
    this(size_t capacity = 0) pure nothrow @safe
    {
        store = new Entry[](capacity);
    }

    /// Number of keys.
    size_t length() const pure nothrow @nogc @safe
    {
        return count;
    }

    /// The entries in insertion order. Treat as read-only.
    inout(Entry)[] entries() inout pure nothrow @nogc @safe
    {
        return store[0 .. count];
    }

    private void buildIndex() pure nothrow @safe
    {
        size_t sz = 32;
        while (sz < count * 2 + 2)
            sz *= 2;
        table = new int[](sz);
        table[] = -1;
        foreach (i; 0 .. count)
            insertIndex(cast(int) i);
    }

    private void insertIndex(int pos) pure nothrow @nogc @safe
    {
        immutable mask = table.length - 1;
        size_t h = store[pos].key.hash & mask;
        while (table[h] != -1)
            h = (h + 1) & mask;
        table[h] = pos;
    }

    /// Position of `key`, or -1.
    int indexOf(JStr key) pure nothrow @safe
    {
        if (count <= indexThreshold)
        {
            foreach (i; 0 .. count)
                if (store[i].key.sameText(key))
                    return cast(int) i;
            return -1;
        }
        if (table is null)
            buildIndex();
        immutable mask = table.length - 1;
        size_t h = key.hash & mask;
        while (true)
        {
            immutable p = table[h];
            if (p == -1)
                return -1;
            if (store[p].key.sameText(key))
                return p;
            h = (h + 1) & mask;
        }
    }

    /// Position of the key with text `key`, or -1.
    int indexOf(string key) pure nothrow @trusted
    {
        if (count <= indexThreshold)
        {
            foreach (i; 0 .. count)
            {
                const k = store[i].key.s;
                if (k.length == key.length && (key.length == 0 || memcmp(k.ptr, key.ptr, key.length) == 0))
                    return cast(int) i;
            }
            return -1;
        }
        if (table is null)
            buildIndex();
        immutable mask = table.length - 1;
        size_t h = hashBytes(key) & mask;
        while (true)
        {
            immutable p = table[h];
            if (p == -1)
                return -1;
            const k = store[p].key.s;
            if (k.length == key.length && (key.length == 0 || memcmp(k.ptr, key.ptr, key.length) == 0))
                return p;
            h = (h + 1) & mask;
        }
    }

    /// The value stored under `key`; `found` tells whether the key exists.
    Value get(JStr key, out bool found) pure nothrow @safe
    {
        immutable i = indexOf(key);
        found = i >= 0;
        return found ? store[i].val : Value.init;
    }

    /// ditto
    Value get(string key, out bool found) pure nothrow @safe
    {
        immutable i = indexOf(key);
        found = i >= 0;
        return found ? store[i].val : Value.init;
    }

    /// True if the object has the key.
    bool has(JStr key) pure nothrow @safe
    {
        return indexOf(key) >= 0;
    }

    /**
     * Set `key` to `v`: an existing key keeps its position, a new key is appended.
     * Only call this on an object you created yourself and have not published yet.
     */
    void set(JStr key, Value v) pure nothrow @safe
    {
        immutable i = indexOf(key);
        if (i >= 0)
        {
            store[i].val = v;
            return;
        }
        append(key, v);
    }

    /// Append an entry whose key is known to be absent (same restriction as $(LREF set)).
    void append(JStr key, Value v) pure nothrow @safe
    {
        if (count == store.length)
            store.length = count < 4 ? 4 : count * 2;
        store[count] = Entry(key, v);
        ++count;
        sorted = null;
        if (table !is null)
        {
            if (count * 2 > table.length)
                buildIndex();
            else
                insertIndex(cast(int)(count - 1));
        }
    }

    /// A private mutable copy with room for `extra` more entries.
    JObject copy(size_t extra = 0) pure nothrow @trusted
    {
        auto o = new JObject(0);
        o.store = new Entry[](count + extra);
        o.store[0 .. count] = store[0 .. count];
        o.count = count;
        if (table !is null)
            o.table = table.dup;
        return o;
    }

    /// Entry positions ordered by key (code point order); computed once.
    const(uint)[] sortedOrder() pure nothrow @trusted
    {
        if (sorted is null && count > 0)
        {
            auto idx = new uint[](count);
            foreach (i; 0 .. count)
                idx[i] = cast(uint) i;
            auto st = store;
            sort!((a, b) => compareBytes(st[a].key.s, st[b].key.s) < 0)(idx);
            sorted = idx;
        }
        return sorted;
    }
}

/// A JSON value. Scalars are inline; strings, arrays and objects are shared references.
struct Value
{
    /// The type tag.
    Kind kind = Kind.null_;
    private union
    {
        double num_;
        JStr str_;
        JArray arr_;
        JObject obj_;
    }

    /// `null`
    static Value nullValue() pure nothrow @nogc @safe
    {
        return Value.init;
    }

    /// `true` or `false`
    static Value boolean(bool b) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = b ? Kind.true_ : Kind.false_;
        return v;
    }

    /// A number.
    static Value number(double d) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.number;
        v.num_ = d;
        return v;
    }

    /// A string value sharing an existing $(LREF JStr).
    static Value string_(JStr s) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.string_;
        v.str_ = s;
        return v;
    }

    /// A string value (takes ownership of `s`, which must not be mutated afterwards).
    static Value string_(string s) pure nothrow @safe
    {
        return string_(new JStr(s));
    }

    /// An array value wrapping `items` (which must not be mutated afterwards).
    static Value array(Value[] items) pure nothrow @trusted
    {
        Value v;
        v.kind = Kind.array;
        v.arr_ = new JArray(items);
        return v;
    }

    /// An object value.
    static Value object(JObject o) pure nothrow @nogc @trusted
    {
        Value v;
        v.kind = Kind.object;
        v.obj_ = o;
        return v;
    }

    /// The number (only valid if `kind == Kind.number`).
    double num() const pure nothrow @nogc @trusted
    {
        assert(kind == Kind.number);
        return num_;
    }

    /// The shared string (only valid for strings).
    JStr jstr() const pure nothrow @nogc @trusted
    {
        assert(kind == Kind.string_);
        return cast(JStr) str_;
    }

    /// The string text (only valid for strings).
    string str() const pure nothrow @nogc @trusted
    {
        assert(kind == Kind.string_);
        return (cast(JStr) str_).s;
    }

    /// The elements (only valid for arrays). Do not modify.
    Value[] items() const pure nothrow @nogc @trusted
    {
        assert(kind == Kind.array);
        return (cast(JArray) arr_).items;
    }

    /// The object (only valid for objects). Do not modify.
    JObject obj() const pure nothrow @nogc @trusted
    {
        assert(kind == Kind.object);
        return cast(JObject) obj_;
    }

    /// jq truthiness: everything except `false` and `null`.
    bool truthy() const pure nothrow @nogc @safe
    {
        return kind > Kind.false_;
    }

    /// Structural equality under the jq order.
    bool opEquals(const Value o) const pure nothrow @trusted
    {
        return compare(cast(Value) this, cast(Value) o) == 0;
    }
}

/// Three-way comparison under jq's total order; returns -1, 0 or 1. Allocates nothing.
int compare(Value a, Value b) pure nothrow @trusted
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
        return a.num_ < b.num_ ? -1 : (a.num_ > b.num_ ? 1 : 0);
    case Kind.string_:
        return compareBytes(a.str_.s, b.str_.s);
    case Kind.array:
        {
            auto x = a.arr_.items, y = b.arr_.items;
            immutable n = x.length < y.length ? x.length : y.length;
            foreach (i; 0 .. n)
            {
                immutable c = compare(x[i], y[i]);
                if (c != 0)
                    return c;
            }
            return x.length < y.length ? -1 : (x.length > y.length ? 1 : 0);
        }
    case Kind.object:
        {
            auto x = a.obj_, y = b.obj_;
            if (x is y)
                return 0;
            auto ox = x.sortedOrder(), oy = y.sortedOrder();
            immutable n = ox.length < oy.length ? ox.length : oy.length;
            foreach (i; 0 .. n)
            {
                immutable c = compareBytes(x.store[ox[i]].key.s, y.store[oy[i]].key.s);
                if (c != 0)
                    return c;
            }
            if (ox.length != oy.length)
                return ox.length < oy.length ? -1 : 1;
            foreach (i; 0 .. n)
            {
                immutable c = compare(x.store[ox[i]].val, y.store[oy[i]].val);
                if (c != 0)
                    return c;
            }
            return 0;
        }
    }
}

/// Indices `0 .. n` ordered by the three-way comparison `cmp` on indices; ties keep index order (a stable sort).
uint[] stableOrder(size_t n, scope int delegate(size_t, size_t) @system cmp)
{
    auto idx = new uint[](n);
    foreach (i; 0 .. n)
        idx[i] = cast(uint) i;
    sort!((a, b) {
        immutable c = cmp(a, b);
        return c != 0 ? c < 0 : a < b;
    })(idx);
    return idx;
}

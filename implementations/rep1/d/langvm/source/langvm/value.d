/// Run-time values and heap objects of the virtual machine.
module langvm.value;

import langvm.diag;

/// Tags of run-time values.
enum VT : ubyte
{
    unit, int_, float_, bool_, char_, str, list, map, tuple, strukt, enum_, closure,
}

/// Base class of heap objects.
class Obj
{
}

/// An immutable string: an array of Unicode scalar values.
final class StrObj : Obj
{
    dstring s;
    ulong hash;

    this(dstring s)
    {
        this.s = s;
    }
}

/// A tagged cell: scalars inline, everything else a reference to a heap object.
struct Value
{
    VT t;
    union
    {
        long i;
        double f;
        Obj o;
    }

    static Value int_(long v) pure nothrow @nogc
    {
        Value r;
        r.t = VT.int_;
        r.i = v;
        return r;
    }

    static Value float_(double v) pure nothrow @nogc
    {
        Value r;
        r.t = VT.float_;
        r.f = v;
        return r;
    }

    static Value bool_(bool v) pure nothrow @nogc
    {
        Value r;
        r.t = VT.bool_;
        r.i = v ? 1 : 0;
        return r;
    }

    static Value char_(dchar v) pure nothrow @nogc
    {
        Value r;
        r.t = VT.char_;
        r.i = v;
        return r;
    }

    static Value unit() pure nothrow @nogc
    {
        Value r;
        return r;
    }

    static Value obj(VT t, Obj o) pure nothrow @nogc
    {
        Value r;
        r.t = t;
        r.o = o;
        return r;
    }

    static Value str(dstring s)
    {
        return obj(VT.str, new StrObj(s));
    }
}

private T unsafeCast(T)(Obj o) @trusted pure nothrow @nogc
{
    return cast(T) cast(void*) o;
}

/// The string object of a `str` value.
StrObj asStr(in Value v) @trusted pure nothrow @nogc
{
    return unsafeCast!StrObj(cast() v.o);
}

/// The list object of a `list` value.
ListObj asList(in Value v) @trusted pure nothrow @nogc
{
    return unsafeCast!ListObj(cast() v.o);
}

/// The map object of a `map` value.
MapObj asMap(in Value v) @trusted pure nothrow @nogc
{
    return unsafeCast!MapObj(cast() v.o);
}

/// The aggregate object of a tuple, struct or enum value.
AggObj asAgg(in Value v) @trusted pure nothrow @nogc
{
    return unsafeCast!AggObj(cast() v.o);
}

/// The closure object of a `closure` value.
ClosureObj asClosure(in Value v) @trusted pure nothrow @nogc
{
    return unsafeCast!ClosureObj(cast() v.o);
}

/// A tuple, struct instance or enum value: declaration id, variant index and components.
final class AggObj : Obj
{
    int decl;
    int variant;
    Value[] f;

    this(int decl, int variant, Value[] f)
    {
        this.decl = decl;
        this.variant = variant;
        this.f = f;
    }
}

/// A closure: function index and captured values.
final class ClosureObj : Obj
{
    int fn;
    Value[] up;

    this(int fn, Value[] up)
    {
        this.fn = fn;
        this.up = up;
    }
}

/// A growable list with identity.
final class ListObj : Obj
{
    Value[] buf;
    size_t len;

    this()
    {
    }

    this(Value[] items)
    {
        buf = items;
        len = items.length;
    }

    /// The current elements.
    Value[] items() pure nothrow @nogc
    {
        return buf[0 .. len];
    }

    void reserveFor(size_t extra)
    {
        size_t need = len + extra;
        if (need > buf.length)
        {
            size_t n = buf.length * 2;
            if (n < need)
                n = need;
            if (n < 8)
                n = 8;
            auto nb = new Value[n];
            nb[0 .. len] = buf[0 .. len];
            buf = nb;
        }
    }

    void push(Value v)
    {
        if (len == buf.length)
            reserveFor(1);
        buf[len++] = v;
    }

    Value pop()
    {
        auto v = buf[--len];
        buf[len] = Value.init;
        return v;
    }

    void insertAt(size_t i, Value v)
    {
        reserveFor(1);
        foreach_reverse (k; i .. len)
            buf[k + 1] = buf[k];
        buf[i] = v;
        len++;
    }

    Value removeAt(size_t i)
    {
        auto v = buf[i];
        foreach (k; i .. len - 1)
            buf[k] = buf[k + 1];
        len--;
        buf[len] = Value.init;
        return v;
    }

    void clear()
    {
        buf = null;
        len = 0;
    }
}

/// Hash of a map key (Int, Bool, Char or Str).
ulong hashKey(in Value k)
{
    if (k.t == VT.str)
    {
        auto so = asStr(k);
        if (so.hash == 0)
        {
            ulong h = 0xcbf29ce484222325UL;
            foreach (c; so.s)
            {
                h ^= c;
                h *= 0x100000001b3UL;
            }
            h ^= h >> 32;
            if (h == 0)
                h = 1;
            so.hash = h;
        }
        return so.hash;
    }
    ulong x = cast(ulong) k.i * 0x9E3779B97F4A7C15UL;
    return x ^ (x >> 29);
}

/// Equality of map keys.
bool keyEq(in Value a, in Value b)
{
    if (a.t != b.t)
        return false;
    if (a.t == VT.str)
        return a.o is b.o || asStr(a).s == asStr(b).s;
    return a.i == b.i;
}

/// An insertion-ordered hash map.
final class MapObj : Obj
{
    Value[] keys;
    Value[] vals;
    /// Number of entry slots in use (live and dead).
    size_t used;
    /// Number of live entries.
    size_t count;
    private int[] index;
    private size_t occupied;

    private enum empty = -1;
    private enum tomb = -2;

    /// Returns the entry position of `k` or -1.
    int find(in Value k) const
    {
        if (count == 0)
            return -1;
        ulong h = hashKey(k);
        size_t mask = index.length - 1;
        size_t i = h & mask;
        while (true)
        {
            int e = index[i];
            if (e == empty)
                return -1;
            if (e >= 0 && keyEq(keys[e], k))
                return e;
            i = (i + 1) & mask;
        }
    }

    private void rebuild(size_t minCount)
    {
        // compact entries
        size_t j = 0;
        foreach (i; 0 .. used)
        {
            if (keys[i].t != VT.unit)
            {
                if (i != j)
                {
                    keys[j] = keys[i];
                    vals[j] = vals[i];
                }
                j++;
            }
        }
        foreach (i; j .. used)
        {
            keys[i] = Value.init;
            vals[i] = Value.init;
        }
        used = j;
        size_t cap = 8;
        while (cap < minCount * 3)
            cap *= 2;
        index = new int[cap];
        index[] = empty;
        occupied = 0;
        size_t mask = cap - 1;
        foreach (e; 0 .. used)
        {
            size_t s = hashKey(keys[e]) & mask;
            while (index[s] != empty)
                s = (s + 1) & mask;
            index[s] = cast(int) e;
            occupied++;
        }
    }

    /// Inserts or updates; a present key keeps its position.
    void set(Value k, Value v)
    {
        int e = find(k);
        if (e >= 0)
        {
            vals[e] = v;
            return;
        }
        if ((occupied + 1) * 2 > index.length)
            rebuild(count + 1);
        if (used == keys.length)
        {
            size_t n = keys.length < 8 ? 8 : keys.length * 2;
            auto nk = new Value[n];
            auto nv = new Value[n];
            nk[0 .. used] = keys[0 .. used];
            nv[0 .. used] = vals[0 .. used];
            keys = nk;
            vals = nv;
        }
        keys[used] = k;
        vals[used] = v;
        size_t mask = index.length - 1;
        size_t s = hashKey(k) & mask;
        while (index[s] >= 0)
            s = (s + 1) & mask;
        if (index[s] == empty)
            occupied++;
        index[s] = cast(int) used;
        used++;
        count++;
    }

    /// Removes a key; returns whether it was present.
    bool remove(in Value k)
    {
        if (count == 0)
            return false;
        ulong h = hashKey(k);
        size_t mask = index.length - 1;
        size_t i = h & mask;
        while (true)
        {
            int e = index[i];
            if (e == empty)
                return false;
            if (e >= 0 && keyEq(keys[e], k))
            {
                index[i] = tomb;
                keys[e] = Value.init;
                vals[e] = Value.init;
                count--;
                if (used > 32 && used - count > count)
                    rebuild(count);
                return true;
            }
            i = (i + 1) & mask;
        }
    }

    void clear()
    {
        keys = null;
        vals = null;
        index = null;
        used = count = occupied = 0;
    }

    /// Copies the map (same entries, same order).
    MapObj copy()
    {
        auto m = new MapObj;
        foreach (i; 0 .. used)
            if (keys[i].t != VT.unit)
                m.set(keys[i], vals[i]);
        return m;
    }
}

/// Structural equality (section 10.4).
bool valuesEqual(in Value a, in Value b)
{
    final switch (a.t)
    {
    case VT.unit:
        return true;
    case VT.int_, VT.bool_, VT.char_:
        return a.i == b.i;
    case VT.float_:
        return a.f == b.f;
    case VT.str:
        return a.o is b.o || asStr(a).s == asStr(b).s;
    case VT.list:
        {
            auto x = asList(a);
            auto y = asList(b);
            if (x.len != y.len)
                return false;
            foreach (i; 0 .. x.len)
                if (!valuesEqual(x.buf[i], y.buf[i]))
                    return false;
            return true;
        }
    case VT.map:
        {
            auto x = asMap(a);
            auto y = asMap(b);
            if (x.count != y.count)
                return false;
            foreach (i; 0 .. x.used)
            {
                if (x.keys[i].t == VT.unit)
                    continue;
                int e = y.find(x.keys[i]);
                if (e < 0 || !valuesEqual(x.vals[i], y.vals[e]))
                    return false;
            }
            return true;
        }
    case VT.tuple, VT.strukt, VT.enum_:
        {
            auto x = asAgg(a);
            auto y = asAgg(b);
            if (x.variant != y.variant)
                return false;
            foreach (i; 0 .. x.f.length)
                if (!valuesEqual(x.f[i], y.f[i]))
                    return false;
            return true;
        }
    case VT.closure:
        return a.o is b.o;
    }
}

/// Three-way comparison of strings by scalar value.
int compareStr(dstring a, dstring b) pure nothrow @nogc
{
    size_t n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
    {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

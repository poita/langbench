/// Run-time values (SPEC.md section 14.1).
module langvm.value;

import langvm.types : Ctor;

/// The tag of a run-time value.
enum Tag : ubyte
{
    unit, int_, float_, bool_, char_, str, list, map, tuple, struct_, enum_, closure,
}

/// Base class of every heap object.
class Obj
{
}

/// A string: a sequence of Unicode scalar values (so indexing is O(1)).
final class StrObj : Obj
{
    dstring s;

    this(dstring s)
    {
        this.s = s;
    }
}

/// A mutable list.
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

    /// The live elements.
    Value[] items() @nogc nothrow
    {
        return buf[0 .. len];
    }

    void push(Value v)
    {
        if (len == buf.length)
        {
            auto nb = new Value[buf.length < 4 ? 4 : buf.length * 2];
            nb[0 .. len] = buf[0 .. len];
            buf = nb;
        }
        buf[len++] = v;
    }

    Value pop()
    {
        auto v = buf[--len];
        buf[len] = Value.init;
        return v;
    }

    void insert(size_t i, Value v)
    {
        push(Value.init);
        foreach_reverse (k; i + 1 .. len)
            buf[k] = buf[k - 1];
        buf[i] = v;
    }

    Value removeAt(size_t i)
    {
        auto v = buf[i];
        foreach (k; i .. len - 1)
            buf[k] = buf[k + 1];
        buf[--len] = Value.init;
        return v;
    }

    void clear()
    {
        buf = null;
        len = 0;
    }
}

/// An insertion-ordered hash map. Keys are `Int`, `Bool`, `Char` or `Str`
/// (all keys of one map have the same kind). Deleted entries leave holes that
/// are compacted when they outnumber the live ones.
final class MapObj : Obj
{
    Value[] keys;
    Value[] vals;
    bool[] dead;
    size_t used; // entries in keys/vals, including holes
    size_t live;
    size_t[long] intIndex;
    size_t[dstring] strIndex;

    size_t length() const @nogc nothrow
    {
        return live;
    }

    /// Slot of `k`, or -1.
    long find(Value k)
    {
        if (k.tag == Tag.str)
        {
            if (auto p = k.str.s in strIndex)
                return cast(long)*p;
        }
        else if (auto p = k.i in intIndex)
            return cast(long)*p;
        return -1;
    }

    Value* get(Value k)
    {
        const s = find(k);
        return s < 0 ? null : &vals[s];
    }

    void set(Value k, Value v)
    {
        const s = find(k);
        if (s >= 0)
        {
            vals[s] = v;
            return;
        }
        if (used == keys.length)
        {
            const n = keys.length < 8 ? 8 : keys.length * 2;
            keys.length = n;
            vals.length = n;
            dead.length = n;
        }
        keys[used] = k;
        vals[used] = v;
        dead[used] = false;
        if (k.tag == Tag.str)
            strIndex[k.str.s] = used;
        else
            intIndex[k.i] = used;
        used++;
        live++;
    }

    bool remove(Value k)
    {
        const s = find(k);
        if (s < 0)
            return false;
        if (k.tag == Tag.str)
            strIndex.remove(k.str.s);
        else
            intIndex.remove(k.i);
        dead[s] = true;
        keys[s] = Value.init;
        vals[s] = Value.init;
        live--;
        if (used > 32 && live < used / 2)
            compact();
        return true;
    }

    private void compact()
    {
        size_t j = 0;
        foreach (i; 0 .. used)
        {
            if (dead[i])
                continue;
            keys[j] = keys[i];
            vals[j] = vals[i];
            dead[j] = false;
            if (keys[j].tag == Tag.str)
                strIndex[keys[j].str.s] = j;
            else
                intIndex[keys[j].i] = j;
            j++;
        }
        foreach (i; j .. used)
        {
            keys[i] = Value.init;
            vals[i] = Value.init;
            dead[i] = false;
        }
        used = j;
    }

    void clear()
    {
        keys = null;
        vals = null;
        dead = null;
        used = 0;
        live = 0;
        intIndex = null;
        strIndex = null;
    }

    /// Visit live entries in insertion order.
    int opApply(scope int delegate(ref Value k, ref Value v) dg)
    {
        foreach (i; 0 .. used)
        {
            if (dead[i])
                continue;
            if (auto r = dg(keys[i], vals[i]))
                return r;
        }
        return 0;
    }
}

/// A tuple, struct instance or enum value.
final class AggObj : Obj
{
    /// Declaration id for structs and enums; -1 for tuples.
    int decl;
    /// Variant index for enum values.
    int variant;
    Value[] f;

    this(int decl, int variant, Value[] f)
    {
        this.decl = decl;
        this.variant = variant;
        this.f = f;
    }
}

/// A closure: a function plus its captured values.
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

/// A run-time value: 16 bytes, no allocation for scalars.
struct Value
{
    union
    {
        long i;
        double f;
        Obj o;
    }

    Tag tag;

    static Value ofInt(long v) @nogc nothrow
    {
        Value r;
        r.tag = Tag.int_;
        r.i = v;
        return r;
    }

    static Value ofFloat(double v) @nogc nothrow
    {
        Value r;
        r.tag = Tag.float_;
        r.f = v;
        return r;
    }

    static Value ofBool(bool v) @nogc nothrow
    {
        Value r;
        r.tag = Tag.bool_;
        r.i = v;
        return r;
    }

    static Value ofChar(long v) @nogc nothrow
    {
        Value r;
        r.tag = Tag.char_;
        r.i = v;
        return r;
    }

    static Value ofStr(dstring s)
    {
        Value r;
        r.tag = Tag.str;
        r.o = new StrObj(s);
        return r;
    }

    static Value ofObj(Tag t, Obj o) @nogc nothrow
    {
        Value r;
        r.tag = t;
        r.o = o;
        return r;
    }

    static Value ofList(Value[] items)
    {
        return ofObj(Tag.list, new ListObj(items));
    }

    /// Unchecked views of the heap object; the type checker guarantees the tag.
    StrObj str() @trusted nothrow @nogc
    {
        return cast(StrObj) cast(void*) o;
    }

    ListObj list() @trusted nothrow @nogc
    {
        return cast(ListObj) cast(void*) o;
    }

    MapObj map() @trusted nothrow @nogc
    {
        return cast(MapObj) cast(void*) o;
    }

    AggObj agg() @trusted nothrow @nogc
    {
        return cast(AggObj) cast(void*) o;
    }

    ClosureObj closure() @trusted nothrow @nogc
    {
        return cast(ClosureObj) cast(void*) o;
    }
}

static assert(Value.sizeof == 16);

/// Option/Result style helpers use the variant indices fixed by the prelude:
/// `Some` = 0, `None` = 1, `Ok` = 0, `Err` = 1.
enum int someVariant = 0, noneVariant = 1, okVariant = 0, errVariant = 1;

/// The head constructor of a value, for trait method dispatch.
int ctorOf(const Value v) @nogc nothrow
{
    final switch (v.tag)
    {
    case Tag.int_: return Ctor.int_;
    case Tag.float_: return Ctor.float_;
    case Tag.bool_: return Ctor.bool_;
    case Tag.char_: return Ctor.char_;
    case Tag.str: return Ctor.str;
    case Tag.unit: return Ctor.unit;
    case Tag.list: return Ctor.list;
    case Tag.map: return Ctor.map;
    case Tag.struct_, Tag.enum_:
        return Ctor.firstDecl + (cast(AggObj) cast(void*) v.o).decl;
    case Tag.tuple, Tag.closure:
        return -1;
    }
}

/// Structural equality (SPEC.md section 10.4).
bool valuesEqual(Value a, Value b)
{
    final switch (a.tag)
    {
    case Tag.unit:
        return true;
    case Tag.int_, Tag.bool_, Tag.char_:
        return a.i == b.i;
    case Tag.float_:
        return a.f == b.f;
    case Tag.str:
        return a.str.s == b.str.s;
    case Tag.list:
    {
        auto x = a.list, y = b.list;
        if (x.len != y.len)
            return false;
        foreach (i; 0 .. x.len)
            if (!valuesEqual(x.buf[i], y.buf[i]))
                return false;
        return true;
    }
    case Tag.map:
    {
        auto x = a.map, y = b.map;
        if (x.length != y.length)
            return false;
        foreach (i; 0 .. x.used)
        {
            if (x.dead[i])
                continue;
            auto p = y.get(x.keys[i]);
            if (p is null || !valuesEqual(x.vals[i], *p))
                return false;
        }
        return true;
    }
    case Tag.tuple, Tag.struct_, Tag.enum_:
    {
        auto x = a.agg, y = b.agg;
        if (x.variant != y.variant)
            return false;
        foreach (i; 0 .. x.f.length)
            if (!valuesEqual(x.f[i], y.f[i]))
                return false;
        return true;
    }
    case Tag.closure:
        return false;
    }
}

/// Three-way comparison of two values of an `Ord` type (-1, 0, 1; NaN compares as unordered = 2).
int compareValues(Value a, Value b)
{
    switch (a.tag)
    {
    case Tag.float_:
        if (a.f < b.f)
            return -1;
        if (a.f > b.f)
            return 1;
        if (a.f == b.f)
            return 0;
        return 2;
    case Tag.str:
    {
        import std.algorithm.comparison : cmp;

        const r = cmp(a.str.s, b.str.s);
        return r < 0 ? -1 : (r > 0 ? 1 : 0);
    }
    default:
        return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
    }
}

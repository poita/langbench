/// Value-level operations: indexing, slicing, arithmetic and the builtin
/// functions that do not need to evaluate sub-filters.
module jq.ops;

import std.algorithm.mutation : SwapStrategy;
import std.algorithm.sorting : sort;
import std.array : appender;
import std.exception : assumeUnique;
import std.string : indexOf;

import jq.ast : BinOp;
import jq.error;
import jq.json;
import jq.value;

// ---------------------------------------------------------------------------
// Indexing, slicing, iteration
// ---------------------------------------------------------------------------

/// `t[k]` without raising: returns false if the operation is an error.
bool tryIndex(Value t, Value k, out Value r)
{
    if (k.kind == Kind.String)
    {
        if (t.kind == Kind.Object)
        {
            auto p = t.obj.get(k.str);
            r = p is null ? Value.makeNull() : *p;
            return true;
        }
        if (t.kind == Kind.Null)
        {
            r = Value.makeNull();
            return true;
        }
        return false;
    }
    if (k.kind == Kind.Number)
    {
        if (t.kind == Kind.Array)
        {
            double d = k.num;
            immutable len = t.arr.length;
            if (d != d)
            {
                r = Value.makeNull();
                return true;
            }
            if (d < 0)
                d = d + len;
            if (d < 0 || d >= len)
                r = Value.makeNull();
            else
                r = t.arr[cast(size_t) d];
            return true;
        }
        if (t.kind == Kind.Null)
        {
            r = Value.makeNull();
            return true;
        }
        return false;
    }
    return false;
}

/// The error for a failed `t[k]`.
JqError indexError(Value t, Value k)
{
    if (k.kind == Kind.String && t.kind != Kind.Object)
        return new JqError("Cannot index " ~ t.typeName ~ " with \"" ~ k.str ~ "\"");
    return new JqError("Cannot index " ~ t.typeName ~ " with " ~ k.typeName);
}

/// `t[k]`, raising `JqError` on failure.
Value index(Value t, Value k)
{
    Value r;
    if (!tryIndex(t, k, r))
        throw indexError(t, k);
    return r;
}

/// Number of Unicode code points in UTF-8 text.
size_t codePointCount(const(char)[] s) @trusted pure nothrow @nogc
{
    size_t n = 0;
    foreach (c; cast(const(ubyte)[]) s)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}

private size_t byteOffsetOfCodePoint(const(char)[] s, size_t cp) @trusted pure nothrow @nogc
{
    size_t seen = 0;
    foreach (i, c; cast(const(ubyte)[]) s)
        if ((c & 0xC0) != 0x80)
        {
            if (seen == cp)
                return i;
            ++seen;
        }
    return s.length;
}

/// `t[from:to]` without raising; a null bound means "omitted".
bool trySlice(Value t, Value from, Value to, out Value r)
{
    import std.math : floor, ceil;

    if (t.kind == Kind.Null)
    {
        r = Value.makeNull();
        return true;
    }
    if (t.kind != Kind.Array && t.kind != Kind.String)
        return false;
    if ((from.kind != Kind.Null && from.kind != Kind.Number)
            || (to.kind != Kind.Null && to.kind != Kind.Number))
        return false;
    immutable double len = t.kind == Kind.Array ? t.arr.length : codePointCount(t.str);
    double a = from.kind == Kind.Null ? 0 : floor(from.num);
    double b = to.kind == Kind.Null ? len : ceil(to.num);
    if (a < 0)
        a += len;
    if (b < 0)
        b += len;
    a = a < 0 ? 0 : (a > len ? len : a);
    b = b < 0 ? 0 : (b > len ? len : b);
    if (b < a)
        b = a;
    immutable ia = cast(size_t) a, ib = cast(size_t) b;
    if (t.kind == Kind.Array)
        r = Value.makeArray(t.arr[ia .. ib]);
    else
    {
        immutable ba = byteOffsetOfCodePoint(t.str, ia);
        immutable bb = ib == cast(size_t) len ? t.str.length : byteOffsetOfCodePoint(t.str, ib);
        r = Value.makeString(t.str[ba .. bb]);
    }
    return true;
}

/// The error for a failed slice.
JqError sliceError(Value t)
{
    return new JqError("Cannot index " ~ t.typeName ~ " with object");
}

/// The error for iterating a non-iterable.
JqError iterateError(Value t)
{
    return new JqError("Cannot iterate over " ~ t.typeName);
}

// ---------------------------------------------------------------------------
// Arithmetic and comparison
// ---------------------------------------------------------------------------

/// Applies a binary operator; raises `JqError` for unsupported types.
Value binop(BinOp op, Value a, Value b)
{
    final switch (op)
    {
    case BinOp.add:
        return plus(a, b);
    case BinOp.sub:
        return minus(a, b);
    case BinOp.mul:
        return times(a, b);
    case BinOp.div:
        return divide(a, b);
    case BinOp.mod:
        return modulo(a, b);
    case BinOp.eq:
        return Value.makeBool(equals(a, b));
    case BinOp.ne:
        return Value.makeBool(!equals(a, b));
    case BinOp.lt:
        return Value.makeBool(compare(a, b) < 0);
    case BinOp.le:
        return Value.makeBool(compare(a, b) <= 0);
    case BinOp.gt:
        return Value.makeBool(compare(a, b) > 0);
    case BinOp.ge:
        return Value.makeBool(compare(a, b) >= 0);
    }
}

private JqError typeError(string what, Value a, Value b)
{
    return new JqError(a.typeName ~ " and " ~ b.typeName ~ " cannot be " ~ what);
}

/// `a + b`.
Value plus(Value a, Value b) @trusted
{
    if (a.kind == Kind.Null)
        return b;
    if (b.kind == Kind.Null)
        return a;
    if (a.kind != b.kind)
        throw typeError("added", a, b);
    switch (a.kind)
    {
    case Kind.Number:
        return Value.makeNumber(a.num + b.num);
    case Kind.String:
        return Value.makeString(a.str ~ b.str);
    case Kind.Array:
        if (a.arr.length == 0)
            return b;
        if (b.arr.length == 0)
            return a;
        {
            // `~=` extends in place when `a.arr` is the newest slice of its
            // block (the runtime tracks that), so repeated `. + [x]` is
            // amortized O(|b|); otherwise it copies. Other slices never see
            // the appended elements.
            Value[] r = a.arr;
            r ~= b.arr;
            return Value.makeArray(r);
        }
    case Kind.Object:
        return Value.makeObject(mergeObjects(a.obj, b.obj, false));
    default:
        throw typeError("added", a, b);
    }
}

/// Merges `b` into `a`: existing keys keep their position, new ones are
/// appended; with `deep`, values that are objects on both sides merge
/// recursively. Costs O(|a| + |b|).
JObject mergeObjects(JObject a, JObject b, bool deep)
{
    if (b.length == 0)
        return a;
    if (a.length == 0)
        return b;
    // Fast path: no key of `b` is in `a`, so nothing is replaced.
    if (a.length > 12 || b.length > 12)
    {
        bool disjoint = true;
        foreach (k; b.keys)
            if (a.find(k) >= 0)
            {
                disjoint = false;
                break;
            }
        if (disjoint)
            return a.appendDisjoint(b.keys, b.vals);
    }
    auto keys = new string[a.length + b.length];
    auto vals = new Value[a.length + b.length];
    keys[0 .. a.length] = a.keys[];
    vals[0 .. a.length] = a.vals[];
    size_t n = a.length;
    foreach (i; 0 .. b.length)
    {
        immutable pos = a.find(b.keys[i]);
        if (pos >= 0)
        {
            auto bv = b.vals[i];
            if (deep && vals[pos].kind == Kind.Object && bv.kind == Kind.Object)
                vals[pos] = Value.makeObject(mergeObjects(vals[pos].obj, bv.obj, true));
            else
                vals[pos] = bv;
        }
        else
        {
            keys[n] = b.keys[i];
            vals[n] = b.vals[i];
            ++n;
        }
    }
    return new JObject(keys[0 .. n], vals[0 .. n]);
}

/// `a - b`.
Value minus(Value a, Value b)
{
    if (a.kind == Kind.Number && b.kind == Kind.Number)
        return Value.makeNumber(a.num - b.num);
    if (a.kind == Kind.Array && b.kind == Kind.Array)
    {
        auto r = appender!(Value[])();
        foreach (x; a.arr)
        {
            bool found = false;
            foreach (y; b.arr)
                if (equals(x, y))
                {
                    found = true;
                    break;
                }
            if (!found)
                r.put(x);
        }
        return Value.makeArray(r.data);
    }
    throw typeError("subtracted", a, b);
}

/// `a * b`.
Value times(Value a, Value b) @trusted
{
    if (a.kind == Kind.Number && b.kind == Kind.Number)
        return Value.makeNumber(a.num * b.num);
    if ((a.kind == Kind.String && b.kind == Kind.Number) || (a.kind == Kind.Number && b.kind == Kind.String))
    {
        immutable s = a.kind == Kind.String ? a.str : b.str;
        immutable d = a.kind == Kind.Number ? a.num : b.num;
        if (d < 0 || d != d)
            return Value.makeNull();
        immutable cnt = d >= 1e9 ? cast(size_t) 1_000_000_000 : cast(size_t) d;
        if (cnt == 0 || s.length == 0)
            return Value.makeString("");
        auto buf = new char[s.length * cnt];
        foreach (i; 0 .. cnt)
            buf[i * s.length .. (i + 1) * s.length] = s[];
        return Value.makeString(assumeUnique(buf));
    }
    if (a.kind == Kind.Object && b.kind == Kind.Object)
        return Value.makeObject(mergeObjects(a.obj, b.obj, true));
    throw typeError("multiplied", a, b);
}

/// `a / b`.
Value divide(Value a, Value b)
{
    if (a.kind == Kind.Number && b.kind == Kind.Number)
    {
        if (b.num == 0)
            throw new JqError(a.typeName ~ " and " ~ b.typeName ~ " cannot be divided because the divisor is zero");
        return Value.makeNumber(a.num / b.num);
    }
    if (a.kind == Kind.String && b.kind == Kind.String)
        return splitString(a.str, b.str);
    throw typeError("divided", a, b);
}

/// Splits `s` on every occurrence of `sep` (`""` splits into code points).
Value splitString(string s, string sep)
{
    auto r = appender!(Value[])();
    if (s.length == 0)
        return Value.makeArray([]);
    if (sep.length == 0)
    {
        size_t i = 0;
        while (i < s.length)
        {
            size_t j = i + 1;
            while (j < s.length && (cast(ubyte) s[j] & 0xC0) == 0x80)
                ++j;
            r.put(Value.makeString(s[i .. j]));
            i = j;
        }
        return Value.makeArray(r.data);
    }
    size_t start = 0;
    while (true)
    {
        immutable pos = indexOf(s[start .. $], sep);
        if (pos < 0)
            break;
        r.put(Value.makeString(s[start .. start + pos]));
        start += pos + sep.length;
    }
    r.put(Value.makeString(s[start .. $]));
    return Value.makeArray(r.data);
}

private long toLong(double d) pure nothrow @nogc @safe
{
    if (d != d)
        return 0;
    if (d >= 9.2e18)
        return long.max;
    if (d <= -9.2e18)
        return long.min + 1;
    return cast(long) d;
}

/// `a % b`.
Value modulo(Value a, Value b)
{
    if (a.kind == Kind.Number && b.kind == Kind.Number)
    {
        immutable x = toLong(a.num), y = toLong(b.num);
        if (y == 0)
            throw new JqError(a.typeName ~ " and " ~ b.typeName ~ " cannot be divided because the divisor is zero");
        if (y == -1)
            return Value.makeNumber(0);
        return Value.makeNumber(cast(double)(x % y));
    }
    throw typeError("divided", a, b);
}

/// Unary minus.
Value negate(Value a)
{
    if (a.kind != Kind.Number)
        throw new JqError(a.typeName ~ " cannot be negated");
    return Value.makeNumber(-a.num);
}

// ---------------------------------------------------------------------------
// Builtins on values
// ---------------------------------------------------------------------------

/// `length`.
Value length(Value v)
{
    final switch (v.kind)
    {
    case Kind.Null:
        return Value.makeNumber(0);
    case Kind.False:
    case Kind.True:
        throw new JqError("boolean has no length");
    case Kind.Number:
        return Value.makeNumber(v.num < 0 ? -v.num : v.num);
    case Kind.String:
        return Value.makeNumber(codePointCount(v.str));
    case Kind.Array:
        return Value.makeNumber(v.arr.length);
    case Kind.Object:
        return Value.makeNumber(v.obj.length);
    }
}

/// `keys`.
Value keys(Value v)
{
    if (v.kind == Kind.Object)
    {
        auto ks = v.obj.sortedKeys();
        auto r = new Value[ks.length];
        foreach (i, k; ks)
            r[i] = Value.makeString(k);
        return Value.makeArray(r);
    }
    if (v.kind == Kind.Array)
    {
        auto r = new Value[v.arr.length];
        foreach (i; 0 .. r.length)
            r[i] = Value.makeNumber(i);
        return Value.makeArray(r);
    }
    throw new JqError(v.typeName ~ " has no keys");
}

/// `has(k)`.
Value has(Value v, Value k)
{
    if (v.kind == Kind.Null)
        return Value.makeBool(false);
    if (v.kind == Kind.Object && k.kind == Kind.String)
        return Value.makeBool(v.obj.find(k.str) >= 0);
    if (v.kind == Kind.Array && k.kind == Kind.Number)
    {
        immutable d = k.num;
        return Value.makeBool(d > -1 && d < v.arr.length);
    }
    throw new JqError("Cannot check whether " ~ v.typeName ~ " has a " ~ k.typeName ~ " key");
}

/// The elements of an array or the values of an object; raises otherwise.
Value[] elementsOf(Value v)
{
    if (v.kind == Kind.Array)
        return v.arr;
    if (v.kind == Kind.Object)
        return v.obj.vals;
    throw iterateError(v);
}

/// `add`: sums the elements with `+`, linear in the total size.
Value add(Value v)
{
    auto xs = elementsOf(v);
    Value cur = Value.makeNull();
    size_t i = 0;
    while (i < xs.length)
    {
        auto x = xs[i];
        if (cur.kind == Kind.String && x.kind == Kind.String)
        {
            size_t j = i, total = cur.str.length;
            while (j < xs.length && xs[j].kind == Kind.String)
                total += xs[j++].str.length;
            auto buf = new char[total];
            size_t o = cur.str.length;
            buf[0 .. o] = cur.str[];
            foreach (k; i .. j)
            {
                buf[o .. o + xs[k].str.length] = xs[k].str[];
                o += xs[k].str.length;
            }
            cur = Value.makeString(assumeUnique(buf));
            i = j;
        }
        else if (cur.kind == Kind.Array && x.kind == Kind.Array)
        {
            size_t j = i, total = cur.arr.length;
            while (j < xs.length && xs[j].kind == Kind.Array)
                total += xs[j++].arr.length;
            auto buf = new Value[total];
            size_t o = cur.arr.length;
            buf[0 .. o] = cur.arr[];
            foreach (k; i .. j)
            {
                buf[o .. o + xs[k].arr.length] = xs[k].arr[];
                o += xs[k].arr.length;
            }
            cur = Value.makeArray(buf);
            i = j;
        }
        else if (cur.kind == Kind.Object && x.kind == Kind.Object)
        {
            size_t j = i;
            while (j < xs.length && xs[j].kind == Kind.Object)
                ++j;
            auto b = ObjectBuilder(cur.obj.length + 8);
            foreach (k; 0 .. cur.obj.length)
                b.set(cur.obj.keys[k], cur.obj.vals[k]);
            foreach (k; i .. j)
                foreach (m; 0 .. xs[k].obj.length)
                    b.set(xs[k].obj.keys[m], xs[k].obj.vals[m]);
            cur = Value.makeObject(b.build());
            i = j;
        }
        else
        {
            cur = plus(cur, x);
            ++i;
        }
    }
    return cur;
}

/// An element paired with its sort key `[f]`.
struct Keyed
{
    Value[] key;
    Value val;
}

/// Stable sort by key.
void sortKeyed(Keyed[] ks)
{
    sort!((a, b) => compareArrays(a.key, b.key) < 0, SwapStrategy.stable)(ks);
}

private Value[] sortedCopy(Value[] xs)
{
    auto c = xs.dup;
    sort!((a, b) => compare(a, b) < 0, SwapStrategy.stable)(c);
    return c;
}

private Value[] requireArray(Value v, string what)
{
    if (v.kind != Kind.Array)
        throw new JqError(v.typeName ~ " cannot be " ~ what);
    return v.arr;
}

/// `sort`.
Value sortValues(Value v)
{
    return Value.makeArray(sortedCopy(requireArray(v, "sorted, as it is not an array")));
}

/// `unique`.
Value unique(Value v)
{
    auto s = sortedCopy(requireArray(v, "sorted, as it is not an array"));
    size_t n = 0;
    foreach (x; s)
        if (n == 0 || !equals(s[n - 1], x))
            s[n++] = x;
    return Value.makeArray(s[0 .. n]);
}

/// `reverse`.
Value reverse(Value v)
{
    if (v.kind == Kind.Null)
        return Value.makeArray([]);
    if (v.kind != Kind.Array)
        throw new JqError("Cannot reverse " ~ v.typeName);
    auto r = new Value[v.arr.length];
    foreach (i, x; v.arr)
        r[$ - 1 - i] = x;
    return Value.makeArray(r);
}

/// `min` (first minimal element) / `max` (last maximal element).
Value minMax(Value v, bool wantMax)
{
    auto xs = requireArray(v, "iterated over");
    if (xs.length == 0)
        return Value.makeNull();
    auto best = xs[0];
    foreach (x; xs[1 .. $])
    {
        immutable c = compare(x, best);
        if (wantMax ? c >= 0 : c < 0)
            best = x;
    }
    return best;
}

/// `tostring`.
Value tostring(Value v)
{
    if (v.kind == Kind.String)
        return v;
    return Value.makeString(toJson(v));
}

/// `tonumber`.
Value tonumber(Value v)
{
    if (v.kind == Kind.Number)
        return v;
    if (v.kind == Kind.String)
    {
        double d;
        if (parseNumberText(v.str, d))
            return Value.makeNumber(d);
        throw new JqError("Cannot parse '" ~ v.str ~ "' as a number");
    }
    throw new JqError(v.typeName ~ " cannot be parsed as a number");
}

unittest
{
    auto n = (double d) => Value.makeNumber(d);
    Value r;
    assert(trySlice(Value.makeString("aé😀bc"), n(1), n(4), r) && r.str == "é😀b");
    assert(trySlice(Value.makeString("abc"), n(-2), Value.makeNull(), r) && r.str == "bc");
    assert(trySlice(Value.makeArray([n(1), n(2), n(3)]), Value.makeNull(), n(-1), r) && r.arr.length == 2);
    assert(toJson(modulo(n(-7), n(3))) == "-1" && toJson(modulo(n(7), n(-3))) == "1");
    assert(toJson(splitString("a,b,,c", ",")) == `["a","b","","c"]`);
    assert(toJson(splitString("abc", "")) == `["a","b","c"]`);
    assert(toJson(splitString("", ",")) == `[]`);
    assert(toJson(times(Value.makeString("ab"), n(2))) == `"abab"`);
    assert(toJson(times(Value.makeString("ab"), n(-1))) == `null`);
}

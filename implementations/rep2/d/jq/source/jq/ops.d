/**
 * Value-level operations: arithmetic, comparison, indexing, slicing and the
 * non-generator builtins. Everything here is pure and returns new values.
 */
module jq.ops;

import core.stdc.math : ceil, floor;
import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;
import std.array : appender;
import std.conv : text;

import jq.ast : BinOp;
import jq.errors : JqError;
import jq.json : toJson, tryParseNumber;
import jq.value;

/// Applies a binary operator (`+ - * / %` and the comparisons).
Value binaryOp(BinOp op, Value a, Value b)
{
    final switch (op)
    {
    case BinOp.add:
        return opAdd(a, b);
    case BinOp.sub:
        return opSub(a, b);
    case BinOp.mul:
        return opMul(a, b);
    case BinOp.div:
        return opDiv(a, b);
    case BinOp.mod:
        return opMod(a, b);
    case BinOp.eq:
        return Value.fromBool(compare(a, b) == 0);
    case BinOp.ne:
        return Value.fromBool(compare(a, b) != 0);
    case BinOp.lt:
        return Value.fromBool(compare(a, b) < 0);
    case BinOp.le:
        return Value.fromBool(compare(a, b) <= 0);
    case BinOp.gt:
        return Value.fromBool(compare(a, b) > 0);
    case BinOp.ge:
        return Value.fromBool(compare(a, b) >= 0);
    }
}

private JqError typeError(string what, Value a, Value b)
{
    return new JqError(a.typeName ~ " and " ~ b.typeName ~ " cannot be " ~ what);
}

/// `a + b`.
Value opAdd(Value a, Value b)
{
    if (a.kind == Kind.null_)
        return b;
    if (b.kind == Kind.null_)
        return a;
    if (a.kind != b.kind)
        throw typeError("added", a, b);
    switch (a.kind)
    {
    case Kind.number:
        return Value.fromNumber(a.num + b.num);
    case Kind.string:
        return Value.fromString(a.str ~ b.str);
    case Kind.array:
        return Value.fromArray(a.arr ~ b.arr);
    case Kind.object:
        auto bo = b.obj;
        auto o = a.obj.dup(bo.length);
        foreach (i, k; bo.keys)
            o.set(k, bo.values[i]);
        return Value.fromObject(o);
    default:
        throw typeError("added", a, b);
    }
}

/// `a - b`.
Value opSub(Value a, Value b)
{
    if (a.kind == Kind.number && b.kind == Kind.number)
        return Value.fromNumber(a.num - b.num);
    if (a.kind == Kind.array && b.kind == Kind.array)
    {
        auto r = appender!(Value[]);
        auto bs = b.arr;
        foreach (x; a.arr)
        {
            bool found = false;
            foreach (y; bs)
                if (compare(x, y) == 0)
                {
                    found = true;
                    break;
                }
            if (!found)
                r.put(x);
        }
        return Value.fromArray(r.data);
    }
    throw typeError("subtracted", a, b);
}

private Value deepMerge(Value a, Value b)
{
    auto bo = b.obj;
    auto o = a.obj.dup(bo.length);
    foreach (i, k; bo.keys)
    {
        auto v = bo.values[i];
        immutable at = o.find(k);
        if (at >= 0 && v.kind == Kind.object && o.values[at].kind == Kind.object)
            o.replaceAt(at, deepMerge(o.values[at], v));
        else
            o.set(k, v);
    }
    return Value.fromObject(o);
}

private Value repeatString(string s, double n)
{
    if (n < 0)
        return Value.nil;
    immutable count = cast(size_t)(n > 1e9 ? 1e9 : n);
    auto r = appender!(char[]);
    r.reserve(s.length * count);
    foreach (_; 0 .. count)
        r.put(s);
    return Value.fromString(cast(string) r.data);
}

/// `a * b`.
Value opMul(Value a, Value b)
{
    if (a.kind == Kind.number && b.kind == Kind.number)
        return Value.fromNumber(a.num * b.num);
    if (a.kind == Kind.string && b.kind == Kind.number)
        return repeatString(a.str, b.num);
    if (a.kind == Kind.number && b.kind == Kind.string)
        return repeatString(b.str, a.num);
    if (a.kind == Kind.object && b.kind == Kind.object)
        return deepMerge(a, b);
    throw typeError("multiplied", a, b);
}

/// Splits `s` on the separator `sep` (an empty separator splits into code points).
string[] splitString(string s, string sep)
{
    string[] r;
    if (s.length == 0)
        return r;
    if (sep.length == 0)
    {
        import std.utf : stride;

        for (size_t i = 0; i < s.length;)
        {
            immutable n = stride(s, i);
            r ~= s[i .. i + n];
            i += n;
        }
        return r;
    }
    size_t start = 0, i = 0;
    while (i + sep.length <= s.length)
    {
        if (s[i] == sep[0] && s[i .. i + sep.length] == sep)
        {
            r ~= s[start .. i];
            i += sep.length;
            start = i;
        }
        else
            i++;
    }
    r ~= s[start .. $];
    return r;
}

/// `a / b`.
Value opDiv(Value a, Value b)
{
    if (a.kind == Kind.number && b.kind == Kind.number)
    {
        if (b.num == 0)
            throw typeError("divided because the divisor is zero", a, b);
        return Value.fromNumber(a.num / b.num);
    }
    if (a.kind == Kind.string && b.kind == Kind.string)
    {
        auto parts = splitString(a.str, b.str);
        auto r = new Value[parts.length];
        foreach (i, p; parts)
            r[i] = Value.fromString(p);
        return Value.fromArray(r);
    }
    throw typeError("divided", a, b);
}

private long truncToLong(double d) @safe pure nothrow @nogc
{
    if (d >= 9.2233720368547758e18)
        return long.max;
    if (d <= -9.2233720368547758e18)
        return long.min;
    return cast(long) d;
}

/// `a % b`.
Value opMod(Value a, Value b)
{
    if (a.kind != Kind.number || b.kind != Kind.number)
        throw typeError("divided", a, b);
    immutable x = truncToLong(a.num), y = truncToLong(b.num);
    if (y == 0)
        throw typeError("divided because the divisor is zero", a, b);
    if (y == -1)
        return Value.fromNumber(0);
    return Value.fromNumber(cast(double)(x % y));
}

/// Negation (`-a`).
Value opNeg(Value a)
{
    if (a.kind != Kind.number)
        throw new JqError(a.typeName ~ " cannot be negated");
    return Value.fromNumber(-a.num);
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// `t[k]`. Returns false (and leaves `result` untouched) if the operation is an error.
bool tryIndex(Value t, Value k, out Value result)
{
    if (k.kind == Kind.string)
    {
        if (t.kind == Kind.object)
        {
            auto p = k.str in t.obj;
            result = p is null ? Value.nil : *p;
            return true;
        }
        if (t.kind == Kind.null_)
        {
            result = Value.nil;
            return true;
        }
        return false;
    }
    if (k.kind == Kind.number)
    {
        if (t.kind == Kind.array)
        {
            auto arr = t.arr;
            double d = k.num;
            if (d != d)
            {
                result = Value.nil;
                return true;
            }
            long i = truncToLong(d);
            if (i < 0)
                i += arr.length;
            result = (i < 0 || i >= arr.length) ? Value.nil : arr[cast(size_t) i];
            return true;
        }
        if (t.kind == Kind.null_)
        {
            result = Value.nil;
            return true;
        }
        return false;
    }
    return false;
}

/// `t[k]`, raising an error when not applicable.
Value index(Value t, Value k)
{
    Value r;
    if (tryIndex(t, k, r))
        return r;
    if (k.kind == Kind.string || k.kind == Kind.number)
        throw new JqError("cannot index " ~ t.typeName ~ " with " ~ (k.kind == Kind.string ? "string" : "number"));
    throw new JqError("cannot index " ~ t.typeName ~ " with " ~ k.typeName);
}

/// Computes `t[from:to]`; a missing bound is passed as `hasFrom`/`hasTo` = false.
bool trySlice(Value t, bool hasFrom, Value from, bool hasTo, Value to, out Value result)
{
    if (t.kind == Kind.null_)
    {
        result = Value.nil;
        return true;
    }
    if (t.kind != Kind.array && t.kind != Kind.string)
        return false;
    if ((hasFrom && from.kind != Kind.number) || (hasTo && to.kind != Kind.number))
        return false;
    size_t len;
    if (t.kind == Kind.array)
        len = t.arr.length;
    else
        len = codePointLength(t.str);
    double s = hasFrom ? floor(from.num) : 0;
    double e = hasTo ? ceil(to.num) : cast(double) len;
    if (s < 0)
        s += len;
    if (e < 0)
        e += len;
    if (s < 0)
        s = 0;
    if (s > len)
        s = len;
    if (e > len)
        e = len;
    if (e < s)
        e = s;
    immutable si = cast(size_t) s, ei = cast(size_t) e;
    if (t.kind == Kind.array)
        result = Value.fromArray(t.arr[si .. ei]);
    else
        result = Value.fromString(codePointSlice(t.str, si, ei));
    return true;
}

/// `t[from:to]` raising an error when not applicable.
Value slice(Value t, bool hasFrom, Value from, bool hasTo, Value to)
{
    Value r;
    if (trySlice(t, hasFrom, from, hasTo, to, r))
        return r;
    if (t.kind == Kind.array || t.kind == Kind.string)
        throw new JqError("start and end indices of a slice must be numbers");
    throw new JqError("cannot slice " ~ t.typeName);
}

/// Number of code points in a UTF-8 string.
size_t codePointLength(string s) @safe pure nothrow @nogc
{
    size_t n = 0;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}

private string codePointSlice(string s, size_t from, size_t to) @safe pure nothrow @nogc
{
    size_t cp = 0, bi = 0, bFrom = s.length, bTo = s.length;
    bool gotFrom = false;
    for (; bi <= s.length; bi++)
    {
        immutable boundary = bi == s.length || (s[bi] & 0xC0) != 0x80;
        if (!boundary)
            continue;
        if (cp == from && !gotFrom)
        {
            bFrom = bi;
            gotFrom = true;
        }
        if (cp == to)
        {
            bTo = bi;
            break;
        }
        cp++;
    }
    return s[bFrom .. bTo];
}

// ---------------------------------------------------------------------------
// Builtins
// ---------------------------------------------------------------------------

/// `length`.
Value builtinLength(Value v)
{
    final switch (v.kind)
    {
    case Kind.null_:
        return Value.fromNumber(0);
    case Kind.number:
        return Value.fromNumber(v.num < 0 ? -v.num : v.num);
    case Kind.string:
        return Value.fromNumber(codePointLength(v.str));
    case Kind.array:
        return Value.fromNumber(v.arr.length);
    case Kind.object:
        return Value.fromNumber(v.obj.length);
    case Kind.false_:
    case Kind.true_:
        throw new JqError("boolean has no length");
    }
}

/// `keys`.
Value builtinKeys(Value v)
{
    if (v.kind == Kind.object)
    {
        auto ks = v.obj.sortedKeys;
        auto r = new Value[ks.length];
        foreach (i, k; ks)
            r[i] = Value.fromString(k);
        return Value.fromArray(r);
    }
    if (v.kind == Kind.array)
    {
        auto r = new Value[v.arr.length];
        foreach (i; 0 .. r.length)
            r[i] = Value.fromNumber(i);
        return Value.fromArray(r);
    }
    throw new JqError(v.typeName ~ " has no keys");
}

/// `has(k)`.
Value builtinHas(Value v, Value k)
{
    if (v.kind == Kind.null_)
        return Value.fromBool(false);
    if (v.kind == Kind.object && k.kind == Kind.string)
        return Value.fromBool(v.obj.find(k.str) >= 0);
    if (v.kind == Kind.array && k.kind == Kind.number)
    {
        immutable i = truncToLong(k.num);
        return Value.fromBool(i >= 0 && i < v.arr.length);
    }
    throw new JqError("cannot check whether " ~ v.typeName ~ " has a " ~ k.typeName ~ " key");
}

/// `tostring`.
Value builtinToString(Value v)
{
    return v.kind == Kind.string ? v : Value.fromString(toJson(v));
}

/// `tonumber`.
Value builtinToNumber(Value v)
{
    if (v.kind == Kind.number)
        return v;
    if (v.kind == Kind.string)
    {
        double d;
        if (tryParseNumber(v.str, d))
            return Value.fromNumber(d);
        throw new JqError("cannot parse '" ~ v.str ~ "' as a number");
    }
    throw new JqError(v.typeName ~ " cannot be parsed as a number");
}

/// `reverse`.
Value builtinReverse(Value v)
{
    if (v.kind == Kind.null_)
        return Value.fromArray(null);
    if (v.kind != Kind.array)
        throw new JqError("cannot reverse " ~ v.typeName);
    auto a = v.arr;
    auto r = new Value[a.length];
    foreach (i, x; a)
        r[a.length - 1 - i] = x;
    return Value.fromArray(r);
}

/// Stable sort of `a` (a fresh array is returned).
Value[] sortedCopy(Value[] a)
{
    auto r = a.dup;
    r.sort!((x, y) => compare(x, y) < 0, SwapStrategy.stable);
    return r;
}

/// `sort`.
Value builtinSort(Value v)
{
    if (v.kind != Kind.array)
        throw new JqError(v.typeName ~ " cannot be sorted, as it is not an array");
    return Value.fromArray(sortedCopy(v.arr));
}

/// `unique`.
Value builtinUnique(Value v)
{
    if (v.kind != Kind.array)
        throw new JqError(v.typeName ~ " cannot be sorted, as it is not an array");
    auto s = sortedCopy(v.arr);
    auto r = appender!(Value[]);
    foreach (i, x; s)
        if (i == 0 || compare(s[i - 1], x) != 0)
            r.put(x);
    return Value.fromArray(r.data);
}

/// `min`.
Value builtinMin(Value v)
{
    if (v.kind != Kind.array)
        throw new JqError(v.typeName ~ " cannot be iterated over");
    auto a = v.arr;
    if (a.length == 0)
        return Value.nil;
    auto best = a[0];
    foreach (x; a[1 .. $])
        if (compare(x, best) < 0)
            best = x;
    return best;
}

/// `max`.
Value builtinMax(Value v)
{
    if (v.kind != Kind.array)
        throw new JqError(v.typeName ~ " cannot be iterated over");
    auto a = v.arr;
    if (a.length == 0)
        return Value.nil;
    auto best = a[0];
    foreach (x; a[1 .. $])
        if (compare(x, best) >= 0)
            best = x;
    return best;
}

/// `add`: sums the elements of an array (or the values of an object) in linear time.
Value builtinAdd(Value v)
{
    Value[] items;
    if (v.kind == Kind.array)
        items = v.arr;
    else if (v.kind == Kind.object)
        items = v.obj.values;
    else
        throw new JqError("cannot iterate over " ~ v.typeName);

    // Find the first non-null element; if all the others share its kind, fold in one pass.
    Kind kind = Kind.null_;
    bool uniform = true;
    foreach (x; items)
    {
        if (x.kind == Kind.null_)
            continue;
        if (kind == Kind.null_)
            kind = x.kind;
        else if (x.kind != kind)
        {
            uniform = false;
            break;
        }
    }
    if (uniform)
    {
        switch (kind)
        {
        case Kind.number:
            double s = 0;
            foreach (x; items)
                if (x.kind == Kind.number)
                    s += x.num;
            return Value.fromNumber(s);
        case Kind.string:
            size_t total = 0;
            foreach (x; items)
                if (x.kind == Kind.string)
                    total += x.str.length;
            auto buf = new char[total];
            size_t at = 0;
            foreach (x; items)
                if (x.kind == Kind.string)
                {
                    buf[at .. at + x.str.length] = x.str;
                    at += x.str.length;
                }
            return Value.fromString(cast(string) buf);
        case Kind.array:
            size_t total = 0;
            foreach (x; items)
                if (x.kind == Kind.array)
                    total += x.arr.length;
            auto buf = new Value[total];
            size_t at = 0;
            foreach (x; items)
                if (x.kind == Kind.array)
                {
                    buf[at .. at + x.arr.length] = x.arr;
                    at += x.arr.length;
                }
            return Value.fromArray(buf);
        case Kind.object:
            auto o = new JObject;
            foreach (x; items)
                if (x.kind == Kind.object)
                    foreach (i, k; x.obj.keys)
                        o.set(k, x.obj.values[i]);
            return Value.fromObject(o);
        default:
            break;
        }
    }
    Value acc = Value.nil;
    foreach (x; items)
        acc = opAdd(acc, x);
    return acc;
}

unittest
{
    import jq.json : parseJson;

    Value p(string s)
    {
        return parseJson(s);
    }

    assert(toJson(opAdd(p(`{"z":1,"a":2}`), p(`{"m":3,"z":9}`))) == `{"z":9,"a":2,"m":3}`);
    assert(toJson(opMul(p(`{"a":{"x":1,"y":2},"q":0}`), p(`{"a":{"z":3,"x":9},"b":1}`))) ==
            `{"a":{"x":9,"y":2,"z":3},"q":0,"b":1}`);
    assert(toJson(opSub(p(`[1,2,3,2]`), p(`[2]`))) == `[1,3]`);
    assert(toJson(opMul(p(`"ab"`), p(`0`))) == `""`);
    assert(toJson(opMul(p(`"ab"`), p(`-1`))) == `null`);
    assert(toJson(opDiv(p(`"a,b,,c"`), p(`","`))) == `["a","b","","c"]`);
    assert(toJson(opDiv(p(`""`), p(`","`))) == `[]`);
    assert(toJson(opDiv(p(`"abc"`), p(`""`))) == `["a","b","c"]`);
    assert(toJson(opMod(p(`-7`), p(`3`))) == `-1`);
    assert(toJson(opMod(p(`7`), p(`-3`))) == `1`);
    assert(toJson(opMod(p(`5.5`), p(`2`))) == `1`);
}

unittest
{
    import jq.json : parseJson;
    import std.exception : assertThrown;

    Value p(string s)
    {
        return parseJson(s);
    }

    assert(toJson(slice(p(`"aéb😀c"`), true, p(`1`), true, p(`4`))) == `"éb😀"`);
    assert(toJson(slice(p(`[1,2,3,4]`), true, p(`-3`), true, p(`-1`))) == `[2,3]`);
    assert(toJson(slice(p(`[1,2,3,4]`), false, Value.nil, true, p(`2`))) == `[1,2]`);
    assert(toJson(slice(p(`[1,2,3,4]`), true, p(`3`), true, p(`1`))) == `[]`);
    assert(toJson(index(p(`[1,2,3]`), p(`-1`))) == `3`);
    assert(toJson(index(p(`[1,2,3]`), p(`5`))) == `null`);
    assertThrown!JqError(index(p(`null`), p(`null`)));
    assertThrown!JqError(index(p(`5`), p(`"a"`)));
    assert(toJson(builtinAdd(p(`[[1],[2,3],null]`))) == `[1,2,3]`);
    assert(toJson(builtinAdd(p(`["a","b"]`))) == `"ab"`);
    assert(toJson(builtinAdd(p(`[]`))) == `null`);
    assert(toJson(builtinAdd(p(`{"a":1,"b":2}`))) == `3`);
    assertThrown!JqError(builtinAdd(p(`[1,"a"]`)));
    assert(toJson(builtinHas(p(`[1,2]`), p(`1.5`))) == `true`);
    assert(toJson(builtinHas(p(`[1,2]`), p(`-1`))) == `false`);
    assert(toJson(builtinUnique(p(`[3,1,3,2,1]`))) == `[1,2,3]`);
}

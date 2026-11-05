/// Arithmetic, comparison and path-access primitives on values.
module jq.arith;

import jq.ast : BinOp;
import jq.compare;
import jq.errors;
import jq.value;

/// Number of code points in a UTF-8 string.
size_t cpLength(string s) pure nothrow @nogc @trusted
{
    size_t n = 0;
    foreach (c; cast(const(ubyte)[]) s)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}

/// Byte offset of the `cp`-th code point of `s` (clamped to `s.length`).
size_t cpOffset(string s, size_t cp) pure nothrow @nogc @trusted
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

private string concat(string a, string b) pure nothrow @trusted
{
    auto r = new char[a.length + b.length];
    r[0 .. a.length] = a[];
    r[a.length .. $] = b[];
    return cast(string) r;
}

/// `a + b`.
Value add(Value a, Value b)
{
    if (a.tag == Tag.null_)
        return b;
    if (b.tag == Tag.null_)
        return a;
    if (a.tag != b.tag)
        throw new JqError("cannot be added");
    switch (a.tag)
    {
    case Tag.number:
        return mkNum(a.num + b.num);
    case Tag.string_:
        return mkStr(concat(a.str, b.str));
    case Tag.array:
        {
            auto x = a.arr, y = b.arr;
            if (y.length == 0)
                return a;
            if (x.length == 0)
                return b;
            auto r = new Value[x.length + y.length];
            r[0 .. x.length] = x[];
            r[x.length .. $] = y[];
            return mkArr(r);
        }
    case Tag.object:
        {
            auto y = b.obj;
            if (y.length == 0)
                return a;
            auto o = Obj.copyOf(a.obj, y.length);
            foreach (e; y.entries)
                o.set(e.key, e.val);
            return mkObj(o);
        }
    default:
        throw new JqError("cannot be added");
    }
}

/// `a * b` on two objects: recursive merge.
Value deepMerge(Value a, Value b)
{
    auto y = b.obj;
    auto o = Obj.copyOf(a.obj, y.length);
    foreach (e; y.entries)
    {
        immutable i = o.find(e.key);
        if (i >= 0)
        {
            auto cur = o.entries[i].val;
            if (cur.isObject && e.val.isObject)
            {
                o.set(e.key, deepMerge(cur, e.val));
                continue;
            }
        }
        o.set(e.key, e.val);
    }
    return mkObj(o);
}

private Value repeat(string s, double n)
{
    if (n < 0)
        return mkNull();
    immutable count = cast(size_t) n;
    if (count == 0 || s.length == 0)
        return mkStr("");
    auto r = new char[s.length * count];
    foreach (i; 0 .. count)
        r[i * s.length .. (i + 1) * s.length] = s[];
    return mkStr(cast(string) r);
}

/// Split `s` on `sep` (code-point-wise when `sep` is empty).
Value splitString(string s, string sep) pure nothrow @trusted
{
    Value[] parts;
    if (s.length == 0)
        return mkArr(null);
    if (sep.length == 0)
    {
        size_t i = 0;
        while (i < s.length)
        {
            size_t j = i + 1;
            while (j < s.length && (cast(ubyte) s[j] & 0xC0) == 0x80)
                ++j;
            parts ~= mkStr(s[i .. j]);
            i = j;
        }
        return mkArr(parts);
    }
    size_t start = 0, i = 0;
    immutable last = s.length - sep.length;
    while (s.length >= sep.length && i <= last)
    {
        if (s[i] == sep[0] && s[i .. i + sep.length] == sep)
        {
            parts ~= mkStr(s[start .. i]);
            i += sep.length;
            start = i;
        }
        else
            ++i;
    }
    parts ~= mkStr(s[start .. $]);
    return mkArr(parts);
}

/// Evaluate a binary operator.
Value binop(BinOp op, Value a, Value b)
{
    final switch (op)
    {
    case BinOp.add:
        return add(a, b);
    case BinOp.sub:
        if (a.isNumber && b.isNumber)
            return mkNum(a.num - b.num);
        if (a.isArray && b.isArray)
        {
            auto bs = b.arr;
            Value[] r;
            r.reserve(a.len);
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
                    r ~= x;
            }
            return mkArr(r);
        }
        throw new JqError("cannot be subtracted");
    case BinOp.mul:
        if (a.isNumber && b.isNumber)
            return mkNum(a.num * b.num);
        if (a.isString && b.isNumber)
            return repeat(a.str, b.num);
        if (a.isNumber && b.isString)
            return repeat(b.str, a.num);
        if (a.isObject && b.isObject)
            return deepMerge(a, b);
        throw new JqError("cannot be multiplied");
    case BinOp.div:
        if (a.isNumber && b.isNumber)
        {
            if (b.num == 0)
                throw new JqError("cannot be divided because the divisor is zero");
            return mkNum(a.num / b.num);
        }
        if (a.isString && b.isString)
            return splitString(a.str, b.str);
        throw new JqError("cannot be divided");
    case BinOp.mod:
        if (a.isNumber && b.isNumber)
        {
            immutable x = cast(long) a.num, y = cast(long) b.num;
            if (y == 0)
                throw new JqError("cannot be divided because the divisor is zero");
            if (y == -1)
                return mkNum(0);
            return mkNum(cast(double)(x % y));
        }
        throw new JqError("cannot be divided");
    case BinOp.eq:
        return mkBool(compare(a, b) == 0);
    case BinOp.ne:
        return mkBool(compare(a, b) != 0);
    case BinOp.lt:
        return mkBool(compare(a, b) < 0);
    case BinOp.le:
        return mkBool(compare(a, b) <= 0);
    case BinOp.gt:
        return mkBool(compare(a, b) > 0);
    case BinOp.ge:
        return mkBool(compare(a, b) >= 0);
    }
}

/// `-v`.
Value negate(Value v)
{
    if (!v.isNumber)
        throw new JqError("cannot be negated");
    return mkNum(-v.num);
}

/// `t.key`. Returns false if the operation is an error for this input.
bool fieldOf(Value t, string key, out Value r) nothrow @trusted
{
    if (t.tag == Tag.object)
    {
        bool f;
        r = t.op.get(key, f);
        return true;
    }
    if (t.tag == Tag.null_)
    {
        r = mkNull();
        return true;
    }
    return false;
}

/// `t[k]`. Returns false if the operation is an error for this combination.
bool indexOf(Value t, Value k, out Value r) nothrow @trusted
{
    if (k.tag == Tag.string_)
        return fieldOf(t, k.str, r);
    if (k.tag == Tag.number)
    {
        if (t.tag == Tag.array)
        {
            immutable d = k.num;
            long i = d >= 9.0e18 ? long.max : (d <= -9.0e18 ? long.min : cast(long) d);
            if (i < 0)
                i += t.len;
            r = (i >= 0 && i < t.len) ? t.ap[i] : mkNull();
            return true;
        }
        if (t.tag == Tag.null_)
        {
            r = mkNull();
            return true;
        }
    }
    return false;
}

private size_t clampBound(double d, size_t len, bool ceilIt) pure nothrow @nogc @safe
{
    import core.stdc.math : floor, ceil;

    double x = ceilIt ? ceil(d) : floor(d);
    if (x < 0)
        x += len;
    if (x < 0)
        x = 0;
    if (x > len)
        x = len;
    return cast(size_t) x;
}

/// `t[from:to]` (null bounds mean the defaults). False on type error.
bool sliceOf(Value t, Value from, Value to, out Value r) nothrow @trusted
{
    if (t.tag == Tag.null_)
    {
        if ((from.tag != Tag.null_ && from.tag != Tag.number)
                || (to.tag != Tag.null_ && to.tag != Tag.number))
            return false;
        r = mkNull();
        return true;
    }
    if (t.tag != Tag.array && t.tag != Tag.string_)
        return false;
    if ((from.tag != Tag.null_ && from.tag != Tag.number)
            || (to.tag != Tag.null_ && to.tag != Tag.number))
        return false;
    if (t.tag == Tag.array)
    {
        immutable len = t.len;
        size_t a = from.tag == Tag.null_ ? 0 : clampBound(from.num, len, false);
        size_t b = to.tag == Tag.null_ ? len : clampBound(to.num, len, true);
        if (b < a)
            b = a;
        r = mkArr(t.ap[a .. b].dup);
        return true;
    }
    auto s = t.str;
    // fast path: ASCII-only strings index by byte
    size_t len = cpLength(s);
    size_t a = from.tag == Tag.null_ ? 0 : clampBound(from.num, len, false);
    size_t b = to.tag == Tag.null_ ? len : clampBound(to.num, len, true);
    if (b < a)
        b = a;
    immutable ba = cpOffset(s, a);
    immutable bb = ba + cpOffset(s[ba .. $], b - a);
    r = mkStr(s[ba .. bb]);
    return true;
}

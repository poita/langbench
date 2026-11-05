/**
 * Value-level operations: arithmetic, indexing, slicing and the data-oriented
 * builtins (`length`, `keys`, `sort`, `add`, ...).
 *
 * Every function is pure with respect to its arguments (values are immutable)
 * and reports failure by returning an error-tagged `Value` (see
 * `Value.isError`) rather than throwing.
 */
module jq.ops;

import core.stdc.string : memchr, memcmp, memcpy;
import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;
import std.math : floor, ceil;

import jq.json;
import jq.value;

private Value typeError(string what, Value a, Value b = Value.makeNull) nothrow
{
    return Value.makeError(typeName(a.type) ~ " and " ~ typeName(b.type) ~ " cannot be " ~ what);
}

private Value typeError1(string what, Value a) nothrow
{
    return Value.makeError(typeName(a.type) ~ " " ~ what);
}

// ---------------------------------------------------------------------------
// UTF-8 helpers
// ---------------------------------------------------------------------------

/// Number of code points in a UTF-8 string.
size_t codePointCount(string s) pure nothrow @trusted @nogc
{
    size_t n = 0;
    foreach (c; cast(const(ubyte)[]) s)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}

/// Byte offset of the `cps`-th code point at or after byte offset `from`.
private size_t advanceCodePoints(string s, size_t from, size_t cps) pure nothrow @trusted @nogc
{
    size_t i = from;
    while (cps > 0 && i < s.length)
    {
        ++i;
        while (i < s.length && ((cast(ubyte) s[i]) & 0xC0) == 0x80)
            ++i;
        --cps;
    }
    return i;
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

/// Shallow merge: `a` with each key of `b` set in order (right wins).
Value mergeObjects(JObj a, JObj b) nothrow
{
    if (b.length == 0)
        return Value.makeObject(a);
    if (a.length == 0)
        return Value.makeObject(b);
    const useIndex = b.length > 4 && a.length > JObj.linearLimit;
    auto pos = new ptrdiff_t[b.length];
    size_t extra = 0;
    foreach (j; 0 .. b.length)
    {
        const p = useIndex ? a.find(b.keys[j].s) : a.findScan(b.keys[j].s);
        pos[j] = p;
        if (p < 0)
            ++extra;
    }
    auto keys = new JStr[a.length + extra];
    auto vals = new Value[a.length + extra];
    keys[0 .. a.length] = a.keys[];
    vals[0 .. a.length] = a.vals[];
    size_t m = a.length;
    foreach (j; 0 .. b.length)
    {
        if (pos[j] >= 0)
            vals[pos[j]] = b.vals[j];
        else
        {
            keys[m] = b.keys[j];
            vals[m] = b.vals[j];
            ++m;
        }
    }
    return Value.makeObject(new JObj(keys, vals));
}

/// Recursive merge (`*` on objects).
Value deepMerge(JObj a, JObj b) nothrow
{
    if (b.length == 0)
        return Value.makeObject(a);
    if (a.length == 0)
        return Value.makeObject(b);
    const useIndex = b.length > 4 && a.length > JObj.linearLimit;
    auto pos = new ptrdiff_t[b.length];
    size_t extra = 0;
    foreach (j; 0 .. b.length)
    {
        const p = useIndex ? a.find(b.keys[j].s) : a.findScan(b.keys[j].s);
        pos[j] = p;
        if (p < 0)
            ++extra;
    }
    auto keys = new JStr[a.length + extra];
    auto vals = new Value[a.length + extra];
    keys[0 .. a.length] = a.keys[];
    vals[0 .. a.length] = a.vals[];
    size_t m = a.length;
    foreach (j; 0 .. b.length)
    {
        if (pos[j] >= 0)
        {
            Value old = vals[pos[j]];
            if (old.type == Type.object && b.vals[j].type == Type.object)
                vals[pos[j]] = deepMerge(old.obj, b.vals[j].obj);
            else
                vals[pos[j]] = b.vals[j];
        }
        else
        {
            keys[m] = b.keys[j];
            vals[m] = b.vals[j];
            ++m;
        }
    }
    return Value.makeObject(new JObj(keys, vals));
}

/// `a + b`.
Value opAdd(Value a, Value b) nothrow
{
    if (a.type == Type.null_)
        return b;
    if (b.type == Type.null_)
        return a;
    if (a.type != b.type)
        return typeError("added", a, b);
    switch (a.type)
    {
    case Type.number:
        return Value.makeNumber(a.num + b.num);
    case Type.string:
        {
            const x = a.str.s, y = b.str.s;
            if (x.length == 0)
                return b;
            if (y.length == 0)
                return a;
            return Value.makeString(concat(x, y));
        }
    case Type.array:
        {
            auto x = a.arr.items, y = b.arr.items;
            if (x.length == 0)
                return b;
            if (y.length == 0)
                return a;
            auto r = new Value[x.length + y.length];
            r[0 .. x.length] = x[];
            r[x.length .. $] = y[];
            return Value.makeArray(r);
        }
    case Type.object:
        return mergeObjects(a.obj, b.obj);
    default:
        return typeError("added", a, b);
    }
}

private string concat(string x, string y) nothrow @trusted
{
    auto r = new char[x.length + y.length];
    memcpy(r.ptr, x.ptr, x.length);
    memcpy(r.ptr + x.length, y.ptr, y.length);
    return cast(string) r;
}

/// `a - b`.
Value opSub(Value a, Value b) nothrow
{
    if (a.type == Type.number && b.type == Type.number)
        return Value.makeNumber(a.num - b.num);
    if (a.type == Type.array && b.type == Type.array)
    {
        Value[] r;
        r.reserve(a.arr.items.length);
        outer: foreach (x; a.arr.items)
        {
            foreach (y; b.arr.items)
                if (equals(x, y))
                    continue outer;
            r ~= x;
        }
        return Value.makeArray(r);
    }
    return typeError("subtracted", a, b);
}

private Value repeatString(string s, double n) nothrow @trusted
{
    if (n < 0 || n != n)
        return Value.makeNull;
    const count = cast(size_t) n;
    if (count == 0 || s.length == 0)
        return Value.makeString("");
    if (count > (size_t(1) << 31) / s.length)
        return Value.makeError("repeat string result too long");
    auto r = new char[s.length * count];
    foreach (i; 0 .. count)
        memcpy(r.ptr + i * s.length, s.ptr, s.length);
    return Value.makeString(cast(string) r);
}

/// `a * b`.
Value opMul(Value a, Value b) nothrow
{
    if (a.type == Type.number && b.type == Type.number)
        return Value.makeNumber(a.num * b.num);
    if (a.type == Type.string && b.type == Type.number)
        return repeatString(a.str.s, b.num);
    if (a.type == Type.number && b.type == Type.string)
        return repeatString(b.str.s, a.num);
    if (a.type == Type.object && b.type == Type.object)
        return deepMerge(a.obj, b.obj);
    return typeError("multiplied", a, b);
}

/// Split `s` on `sep` (like jq's string division).
Value splitString(string s, string sep) nothrow @trusted
{
    Value[] parts;
    if (s.length == 0)
        return Value.makeArray(parts);
    if (sep.length == 0)
    {
        size_t i = 0;
        while (i < s.length)
        {
            const j = advanceCodePoints(s, i, 1);
            parts ~= Value.makeString(s[i .. j]);
            i = j;
        }
        return Value.makeArray(parts);
    }
    size_t start = 0, i = 0;
    const first = sep[0];
    while (i + sep.length <= s.length)
    {
        auto p = cast(const(char)*) memchr(s.ptr + i, first, s.length - sep.length + 1 - i);
        if (p is null)
            break;
        i = p - s.ptr;
        if (memcmp(s.ptr + i, sep.ptr, sep.length) == 0)
        {
            parts ~= Value.makeString(s[start .. i]);
            i += sep.length;
            start = i;
        }
        else
            ++i;
    }
    parts ~= Value.makeString(s[start .. $]);
    return Value.makeArray(parts);
}

/// `a / b`.
Value opDiv(Value a, Value b) nothrow
{
    if (a.type == Type.number && b.type == Type.number)
    {
        if (b.num == 0)
            return Value.makeError("number and number cannot be divided because the divisor is zero");
        return Value.makeNumber(a.num / b.num);
    }
    if (a.type == Type.string && b.type == Type.string)
        return splitString(a.str.s, b.str.s);
    return typeError("divided", a, b);
}

/// `a % b`.
Value opMod(Value a, Value b) nothrow
{
    if (a.type != Type.number || b.type != Type.number)
        return typeError("divided", a, b);
    const x = toLong(a.num), y = toLong(b.num);
    if (y == 0)
        return Value.makeError("number and number cannot be divided because the divisor is zero");
    if (y == -1)
        return Value.makeNumber(0);
    return Value.makeNumber(cast(double)(x % y));
}

private long toLong(double d) pure nothrow @safe @nogc
{
    if (d != d)
        return 0;
    if (d >= 9.2e18)
        return long.max;
    if (d <= -9.2e18)
        return long.min + 1;
    return cast(long) d;
}

/// Unary minus.
Value opNeg(Value a) nothrow
{
    if (a.type != Type.number)
        return typeError1("cannot be negated", a);
    return Value.makeNumber(-a.num);
}

// ---------------------------------------------------------------------------
// Indexing and slicing
// ---------------------------------------------------------------------------

/// `t[k]` for a string or number `k`.
Value indexValue(Value t, Value k) nothrow
{
    switch (k.type)
    {
    case Type.string:
        if (t.type == Type.object)
            return t.obj.get(k.str.s);
        if (t.type == Type.null_)
            return Value.makeNull;
        return Value.makeError("cannot index " ~ typeName(t.type) ~ " with string");
    case Type.number:
        if (t.type == Type.array)
        {
            auto items = t.arr.items;
            const len = cast(double) items.length;
            double d = k.num;
            if (d != d)
                return Value.makeNull;
            d = d < 0 ? ceil(d) : floor(d);
            if (d < 0)
                d += len;
            if (d < 0 || d >= len)
                return Value.makeNull;
            return items[cast(size_t) d];
        }
        if (t.type == Type.null_)
            return Value.makeNull;
        return Value.makeError("cannot index " ~ typeName(t.type) ~ " with number");
    default:
        return Value.makeError("cannot index " ~ typeName(t.type) ~ " with " ~ typeName(k.type));
    }
}

/// `t[from:to]`; a `null` bound means "open".
Value sliceValue(Value t, Value from, Value to) nothrow
{
    if (t.type == Type.null_)
        return t;
    if (t.type != Type.array && t.type != Type.string)
        return Value.makeError("cannot slice " ~ typeName(t.type));
    if ((from.type != Type.null_ && from.type != Type.number)
        || (to.type != Type.null_ && to.type != Type.number))
        return Value.makeError("start and end indices of an array slice must be numbers");
    const isArr = t.type == Type.array;
    const len = isArr ? t.arr.items.length : codePointCount(t.str.s);
    const dl = cast(double) len;
    double f = from.type == Type.null_ ? 0 : floor(from.num);
    double e = to.type == Type.null_ ? dl : ceil(to.num);
    if (f != f)
        f = 0;
    if (e != e)
        e = dl;
    if (f < 0)
        f += dl;
    if (e < 0)
        e += dl;
    f = f < 0 ? 0 : (f > dl ? dl : f);
    e = e < 0 ? 0 : (e > dl ? dl : e);
    if (e < f)
        e = f;
    const fi = cast(size_t) f, ei = cast(size_t) e;
    if (isArr)
        return Value.makeArray(t.arr.items[fi .. ei].dup);
    const s = t.str.s;
    const b0 = advanceCodePoints(s, 0, fi);
    const b1 = advanceCodePoints(s, b0, ei - fi);
    return Value.makeString(s[b0 .. b1]);
}

// ---------------------------------------------------------------------------
// Builtins on values
// ---------------------------------------------------------------------------

private __gshared JStr[8] typeNames;

shared static this()
{
    foreach (t; [Type.null_, Type.false_, Type.true_, Type.number, Type.string, Type.array, Type.object])
        typeNames[t] = new JStr(typeName(t));
}

/// `type`.
Value opType(Value v) nothrow @trusted
{
    return Value.makeString(typeNames[v.type]);
}

/// `length`.
Value opLength(Value v) nothrow
{
    switch (v.type)
    {
    case Type.null_: return Value.makeNumber(0);
    case Type.number: return Value.makeNumber(v.num < 0 ? -v.num : v.num);
    case Type.string: return Value.makeNumber(cast(double) codePointCount(v.str.s));
    case Type.array: return Value.makeNumber(cast(double) v.arr.items.length);
    case Type.object: return Value.makeNumber(cast(double) v.obj.length);
    default: return typeError1("has no length", v);
    }
}

/// `keys`.
Value opKeys(Value v) nothrow
{
    if (v.type == Type.object)
    {
        auto o = v.obj;
        auto ord = o.sortedOrder;
        auto r = new Value[ord.length];
        foreach (i, p; ord)
            r[i] = Value.makeString(o.keys[p]);
        return Value.makeArray(r);
    }
    if (v.type == Type.array)
    {
        auto r = new Value[v.arr.items.length];
        foreach (i, ref x; r)
            x = Value.makeNumber(cast(double) i);
        return Value.makeArray(r);
    }
    return typeError1("has no keys", v);
}

/// `has(k)`.
Value opHas(Value t, Value k) nothrow
{
    if (t.type == Type.object && k.type == Type.string)
        return Value.makeBool(t.obj.has(k.str.s));
    if (t.type == Type.array && k.type == Type.number)
    {
        const d = k.num;
        return Value.makeBool(d == d && d > -1 && d < cast(double) t.arr.items.length);
    }
    if (t.type == Type.null_)
        return Value.makeBool(false);
    return Value.makeError("cannot check whether " ~ typeName(t.type) ~ " has a " ~ typeName(k.type) ~ " key");
}

/// `tostring`.
Value opToString(Value v) nothrow
{
    if (v.type == Type.string)
        return v;
    return Value.makeString(toJson(v));
}

/// `tonumber`.
Value opToNumber(Value v) nothrow
{
    if (v.type == Type.number)
        return v;
    if (v.type == Type.string)
    {
        double d;
        const s = v.str.s;
        if (s.length > 0 && scanNumber(s, 0, d) == s.length)
            return Value.makeNumber(d);
        return Value.makeError("cannot be parsed as a number");
    }
    return typeError1("cannot be parsed as a number", v);
}

/// Indices `0 .. keys.length` ordered by `keys` (stable: ties keep index order).
uint[] sortedPermutation(const(Value)[] keys) nothrow
{
    auto idx = new uint[keys.length];
    foreach (i, ref x; idx)
        x = cast(uint) i;
    if (idx.length > 1)
        idx.sort!((a, b) {
            const c = compare(keys[a], keys[b]);
            return c < 0 || (c == 0 && a < b);
        });
    return idx;
}

/// `sort`.
Value opSort(Value v) nothrow
{
    if (v.type != Type.array)
        return typeError1("cannot be sorted, as it is not an array", v);
    auto src = v.arr.items;
    auto idx = sortedPermutation(src);
    auto r = new Value[src.length];
    foreach (i, p; idx)
        r[i] = src[p];
    return Value.makeArray(r);
}

/// `unique`.
Value opUnique(Value v) nothrow
{
    if (v.type != Type.array)
        return typeError1("cannot be sorted, as it is not an array", v);
    auto src = v.arr.items;
    auto idx = sortedPermutation(src);
    Value[] r;
    r.reserve(src.length);
    foreach (p; idx)
        if (r.length == 0 || !equals(r[$ - 1], src[p]))
            r ~= src[p];
    return Value.makeArray(r);
}

/// `reverse`.
Value opReverse(Value v) nothrow
{
    if (v.type == Type.null_)
        return Value.makeArray(null);
    if (v.type != Type.array)
        return typeError1("cannot be reversed, as it is not an array", v);
    auto src = v.arr.items;
    auto r = new Value[src.length];
    foreach (i, x; src)
        r[$ - 1 - i] = x;
    return Value.makeArray(r);
}

/// `min` (first minimal element) or `max` (last maximal element).
Value opMinMax(Value v, bool wantMax) nothrow
{
    if (v.type != Type.array)
        return typeError1("cannot be iterated over for min/max", v);
    auto src = v.arr.items;
    if (src.length == 0)
        return Value.makeNull;
    Value best = src[0];
    foreach (x; src[1 .. $])
    {
        const c = compare(x, best);
        if (wantMax ? c >= 0 : c < 0)
            best = x;
    }
    return best;
}

/// Accumulates `null + x1 + x2 + ...` in linear time using private builders.
struct Adder
{
    private enum Mode : ubyte { none, number, text, array, object, other }
    private Mode mode;
    private double sum = 0;
    private char[] text;
    private Value[] items;
    private JObj obj;
    private Value other;

    /// Fold in one more element. Returns an error value on a type mismatch, else null.
    Value push(Value x) nothrow
    {
        if (x.type == Type.null_)
            return Value.makeNull;
        final switch (mode)
        {
        case Mode.none:
            switch (x.type)
            {
            case Type.number:
                mode = Mode.number;
                sum = x.num;
                break;
            case Type.string:
                mode = Mode.text;
                text ~= x.str.s;
                break;
            case Type.array:
                mode = Mode.array;
                items ~= x.arr.items;
                break;
            case Type.object:
                mode = Mode.object;
                obj = x.obj.copy();
                break;
            default:
                mode = Mode.other;
                other = x;
            }
            break;
        case Mode.number:
            if (x.type != Type.number)
                return typeError("added", Value.makeNumber(sum), x);
            sum += x.num;
            break;
        case Mode.text:
            if (x.type != Type.string)
                return typeError("added", Value.makeString("") , x);
            text ~= x.str.s;
            break;
        case Mode.array:
            if (x.type != Type.array)
                return typeError("added", Value.makeArray(null), x);
            items ~= x.arr.items;
            break;
        case Mode.object:
            if (x.type != Type.object)
                return typeError("added", Value.makeObject(obj), x);
            foreach (i; 0 .. x.obj.length)
                obj.set(x.obj.keys[i], x.obj.vals[i]);
            break;
        case Mode.other:
            return typeError("added", other, x);
        }
        return Value.makeNull;
    }

    /// The accumulated value.
    Value result() nothrow @trusted
    {
        final switch (mode)
        {
        case Mode.none: return Value.makeNull;
        case Mode.number: return Value.makeNumber(sum);
        case Mode.text: return Value.makeString(cast(string) text);
        case Mode.array: return Value.makeArray(items);
        case Mode.object: return Value.makeObject(obj);
        case Mode.other: return other;
        }
    }
}

/// `add` on an array or object.
Value opAddAll(Value v) nothrow
{
    Adder a;
    if (v.type == Type.array)
    {
        foreach (x; v.arr.items)
        {
            auto e = a.push(x);
            if (e.isError)
                return e;
        }
    }
    else if (v.type == Type.object)
    {
        foreach (x; v.obj.vals)
        {
            auto e = a.push(x);
            if (e.isError)
                return e;
        }
    }
    else
        return Value.makeError("cannot iterate over " ~ typeName(v.type));
    return a.result;
}

/// Apply a binary operator.
Value applyBinary(BinOp op, Value a, Value b) nothrow
{
    final switch (op)
    {
    case BinOp.add: return opAdd(a, b);
    case BinOp.sub: return opSub(a, b);
    case BinOp.mul: return opMul(a, b);
    case BinOp.div: return opDiv(a, b);
    case BinOp.mod: return opMod(a, b);
    case BinOp.eq: return Value.makeBool(compare(a, b) == 0);
    case BinOp.ne: return Value.makeBool(compare(a, b) != 0);
    case BinOp.lt: return Value.makeBool(compare(a, b) < 0);
    case BinOp.le: return Value.makeBool(compare(a, b) <= 0);
    case BinOp.gt: return Value.makeBool(compare(a, b) > 0);
    case BinOp.ge: return Value.makeBool(compare(a, b) >= 0);
    }
}

/// Binary operators of the filter language.
enum BinOp : ubyte { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge }

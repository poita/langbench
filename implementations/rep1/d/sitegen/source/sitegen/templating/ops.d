/// Operators and value semantics of the template language: truthiness,
/// arithmetic, comparison, subscripting and sequence views.
module sitegen.templating.ops;

import sitegen.templating.ast : BinOp, CmpOp;
import sitegen.templating.errors;
import sitegen.templating.value;
import std.math : floor, fmod, pow;
import std.utf : stride;

/// The truthiness of `v`; the undefined value is an error.
bool truthy(Value v)
{
    final switch (v.kind)
    {
    case Kind.undefined:
        throw undefinedError("truthiness of undefined");
    case Kind.none:
        return false;
    case Kind.boolean:
    case Kind.integer:
        return v.i != 0;
    case Kind.floating:
        return v.d != 0;
    case Kind.text:
        return v.s.length != 0;
    case Kind.list:
        return v.items.length != 0;
    case Kind.dict:
        return v.dict.length != 0;
    case Kind.macroDef:
    case Kind.rangeFn:
    case Kind.superFn:
    case Kind.loop:
        return true;
    }
}

/// Split a string into its code points, each as a one-character string.
string[] codePoints(string s)
{
    string[] r;
    size_t i = 0;
    while (i < s.length)
    {
        immutable n = stride(s, i);
        r ~= s[i .. i + n];
        i += n;
    }
    return r;
}

/// The sequence view of a value (list elements, dict keys, string characters).
Value[] sequenceView(Value v)
{
    switch (v.kind)
    {
    case Kind.undefined:
        throw undefinedError("iterating undefined");
    case Kind.list:
        return v.items;
    case Kind.dict:
    {
        auto d = v.dict;
        auto r = new Value[d.keys.length];
        foreach (k, key; d.keys)
            r[k] = Value.of(key);
        return r;
    }
    case Kind.text:
    {
        auto cps = codePoints(v.s);
        auto r = new Value[cps.length];
        foreach (k, c; cps)
            r[k] = Value.of(c);
        return r;
    }
    default:
        throw typeError("not a sequence");
    }
}

/// `a == b`: numbers numerically, strings, lists and dicts structurally.
bool valuesEqual(Value a, Value b)
{
    if (a.isUndefined || b.isUndefined)
        throw undefinedError("comparing undefined");
    if (a.isNumber && b.isNumber)
    {
        if (a.kind == Kind.floating || b.kind == Kind.floating)
            return a.asDouble == b.asDouble;
        return a.i == b.i;
    }
    if (a.kind != b.kind)
        return false;
    switch (a.kind)
    {
    case Kind.none:
        return true;
    case Kind.text:
        return a.s == b.s;
    case Kind.list:
    {
        auto x = a.items, y = b.items;
        if (x.length != y.length)
            return false;
        foreach (k; 0 .. x.length)
            if (!valuesEqual(x[k], y[k]))
                return false;
        return true;
    }
    case Kind.dict:
    {
        auto x = a.dict, y = b.dict;
        if (x.length != y.length)
            return false;
        foreach (k, key; x.keys)
        {
            Value other;
            if (!y.tryGet(key, other) || !valuesEqual(x.values[k], other))
                return false;
        }
        return true;
    }
    default:
        return a.o is b.o && a.o !is null;
    }
}

private int orderValues(Value a, Value b)
{
    if (a.isNumber && b.isNumber)
    {
        if (a.kind == Kind.floating || b.kind == Kind.floating)
        {
            immutable x = a.asDouble, y = b.asDouble;
            return x < y ? -1 : (x > y ? 1 : 0);
        }
        return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
    }
    if (a.kind == Kind.text && b.kind == Kind.text)
    {
        import std.algorithm.comparison : cmp;

        return a.s < b.s ? -1 : (a.s > b.s ? 1 : 0);
    }
    throw typeError("values are not orderable");
}

private bool bytesContain(string hay, string needle) pure nothrow @safe @nogc
{
    if (needle.length == 0)
        return true;
    if (needle.length > hay.length)
        return false;
    immutable first = needle[0];
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i] == first && hay[i .. i + needle.length] == needle)
            return true;
    return false;
}

/// Evaluate one comparison operator.
bool compareValues(CmpOp op, Value a, Value b)
{
    if (a.isUndefined || b.isUndefined)
        throw undefinedError("comparing undefined");
    final switch (op)
    {
    case CmpOp.eq:
        return valuesEqual(a, b);
    case CmpOp.ne:
        return !valuesEqual(a, b);
    case CmpOp.lt:
        return orderValues(a, b) < 0;
    case CmpOp.le:
        return orderValues(a, b) <= 0;
    case CmpOp.gt:
        return orderValues(a, b) > 0;
    case CmpOp.ge:
        return orderValues(a, b) >= 0;
    case CmpOp.in_:
        return contains(b, a);
    case CmpOp.notIn:
        return !contains(b, a);
    }
}

private bool contains(Value container, Value item)
{
    switch (container.kind)
    {
    case Kind.text:
        if (item.kind != Kind.text)
            throw typeError("'in <string>' requires a string");
        return bytesContain(container.s, item.s);
    case Kind.dict:
    {
        if (item.kind != Kind.text)
            return false;
        Value tmp;
        return container.dict.tryGet(item.s, tmp);
    }
    case Kind.list:
        foreach (e; container.items)
            if (valuesEqual(e, item))
                return true;
        return false;
    default:
        throw typeError("'in' needs a string, list or dict");
    }
}

/// Unary minus.
Value negateValue(Value v)
{
    if (v.isUndefined)
        throw undefinedError("negating undefined");
    if (v.kind == Kind.floating)
        return Value.of(-v.d);
    if (v.isNumber)
        return Value.of(-v.i);
    throw typeError("cannot negate");
}

private long floorDivLong(long a, long b)
{
    long q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0)))
        --q;
    return q;
}

private long modLong(long a, long b)
{
    long m = a % b;
    if (m != 0 && ((m < 0) != (b < 0)))
        m += b;
    return m;
}

private double modDouble(double a, double b)
{
    double r = fmod(a, b);
    if (r != 0 && ((r < 0) != (b < 0)))
        r += b;
    return r;
}

/// Evaluate an arithmetic / concatenation operator.
Value binaryOp(BinOp op, Value a, Value b)
{
    if (a.isUndefined || b.isUndefined)
        throw undefinedError("arithmetic on undefined");
    immutable numbers = a.isNumber && b.isNumber;
    immutable isFloat = a.kind == Kind.floating || b.kind == Kind.floating;
    final switch (op)
    {
    case BinOp.add:
        if (numbers)
            return isFloat ? Value.of(a.asDouble + b.asDouble) : Value.of(a.i + b.i);
        if (a.kind == Kind.text && b.kind == Kind.text)
            return Value.of(a.s ~ b.s);
        if (a.kind == Kind.list && b.kind == Kind.list)
            return Value.of(a.items ~ b.items);
        throw typeError("bad operands for +");
    case BinOp.sub:
        if (numbers)
            return isFloat ? Value.of(a.asDouble - b.asDouble) : Value.of(a.i - b.i);
        throw typeError("bad operands for -");
    case BinOp.mul:
        if (numbers)
            return isFloat ? Value.of(a.asDouble * b.asDouble) : Value.of(a.i * b.i);
        if (a.kind == Kind.text && (b.kind == Kind.integer || b.kind == Kind.boolean))
            return Value.of(repeat(a.s, b.i));
        if (b.kind == Kind.text && (a.kind == Kind.integer || a.kind == Kind.boolean))
            return Value.of(repeat(b.s, a.i));
        throw typeError("bad operands for *");
    case BinOp.div:
        if (!numbers)
            throw typeError("bad operands for /");
        if (b.asDouble == 0)
            throw typeError("division by zero");
        return Value.of(a.asDouble / b.asDouble);
    case BinOp.floorDiv:
        if (!numbers)
            throw typeError("bad operands for //");
        if (b.asDouble == 0)
            throw typeError("division by zero");
        return isFloat ? Value.of(floor(a.asDouble / b.asDouble)) : Value.of(floorDivLong(a.i, b.i));
    case BinOp.mod:
        if (!numbers)
            throw typeError("bad operands for %");
        if (b.asDouble == 0)
            throw typeError("modulo by zero");
        return isFloat ? Value.of(modDouble(a.asDouble, b.asDouble)) : Value.of(modLong(a.i, b.i));
    case BinOp.pow:
        if (!numbers)
            throw typeError("bad operands for **");
        if (isFloat)
            return Value.of(pow(a.asDouble, b.asDouble));
        if (b.i >= 0)
        {
            long r = 1;
            foreach (_; 0 .. b.i)
                r *= a.i;
            return Value.of(r);
        }
        if (a.i == 0)
            throw typeError("0 to a negative power");
        return Value.of(pow(cast(double) a.i, cast(double) b.i));
    case BinOp.concat:
        return Value.of(toDisplay(a) ~ toDisplay(b));
    }
}

private string repeat(string s, long n)
{
    if (n <= 0)
        return "";
    import std.array : replicate;

    return replicate(s, cast(size_t) n);
}

/// `a.NAME` / `a[key]`.
Value getItem(Value a, Value key)
{
    if (a.isUndefined || key.isUndefined)
        throw undefinedError("subscript of undefined");
    switch (a.kind)
    {
    case Kind.dict:
    {
        if (key.kind != Kind.text)
            return Value.undefined;
        Value r;
        if (a.dict.tryGet(key.s, r))
            return r;
        return Value.undefined;
    }
    case Kind.list:
    {
        if (key.kind != Kind.integer && key.kind != Kind.boolean)
            return Value.undefined;
        auto items = a.items;
        long i = key.i;
        if (i < 0)
            i += cast(long) items.length;
        if (i < 0 || i >= cast(long) items.length)
            return Value.undefined;
        return items[cast(size_t) i];
    }
    case Kind.text:
    {
        if (key.kind != Kind.integer && key.kind != Kind.boolean)
            return Value.undefined;
        long i = key.i;
        if (i < 0)
        {
            i += cast(long) countCodePoints(a.s);
            if (i < 0)
                return Value.undefined;
        }
        size_t at = 0;
        long n = 0;
        while (at < a.s.length)
        {
            immutable len = stride(a.s, at);
            if (n == i)
                return Value.of(a.s[at .. at + len]);
            at += len;
            ++n;
        }
        return Value.undefined;
    }
    case Kind.loop:
    {
        if (key.kind != Kind.text)
            return Value.undefined;
        switch (key.s)
        {
        case "index": return Value.of(a.i + 1);
        case "index0": return Value.of(a.i);
        case "first": return Value.of(a.i == 0);
        case "last": return Value.of(a.i + 1 == a.aux);
        case "length": return Value.of(a.aux);
        default: return Value.undefined;
        }
    }
    default:
        return Value.undefined;
    }
}

/// Number of code points in `s`.
size_t countCodePoints(string s)
{
    size_t n = 0, i = 0;
    while (i < s.length)
    {
        i += stride(s, i);
        ++n;
    }
    return n;
}

/// Arithmetic, comparison and subscript semantics on values.
module jinjalite.operators;

import core.stdc.math : fmod, floor, pow, copysign;
import std.array : appender, replicate;
import std.string : indexOf;
import jinjalite.errors;
import jinjalite.value;

/// Binary arithmetic operators (`~` is string concatenation).
enum BinOp : ubyte { add, sub, mul, div, floorDiv, mod, pow, concat }

/// Comparison operators, including membership.
enum CmpOp : ubyte { eq, ne, lt, le, gt, ge, in_, notIn }

private void requireBothDefined(Value a, Value b)
{
    requireDefined(a);
    requireDefined(b);
}

/// Apply `op`; throws `TemplateError` of kind `type` or `undefined` on misuse.
Value binaryOp(BinOp op, Value a, Value b)
{
    requireBothDefined(a, b);
    final switch (op)
    {
    case BinOp.add:      return add(a, b);
    case BinOp.sub:      return arith(a, b, "-", (x, y) => x - y, (x, y) => x - y);
    case BinOp.mul:      return mul(a, b);
    case BinOp.div:      return divide(a, b);
    case BinOp.floorDiv: return floorDivide(a, b);
    case BinOp.mod:      return modulo(a, b);
    case BinOp.pow:      return power(a, b);
    case BinOp.concat:   return Value.text(toStr(a) ~ toStr(b));
    }
}

private Value arith(Value a, Value b, string sym, long function(long, long) onInts,
    double function(double, double) onFloats)
{
    if (!a.isNumber || !b.isNumber)
        typeError("unsupported operand types for " ~ sym);
    if (a.kind != Kind.floating && b.kind != Kind.floating)
        return Value.integer(onInts(a.i, b.i));
    return Value.floating(onFloats(a.asDouble, b.asDouble));
}

private Value add(Value a, Value b)
{
    if (a.isNumber && b.isNumber)
        return arith(a, b, "+", (x, y) => x + y, (x, y) => x + y);
    if (a.kind == Kind.text && b.kind == Kind.text)
        return Value.text(a.s ~ b.s);
    if (a.kind == Kind.list && b.kind == Kind.list)
        return Value.list(a.items ~ b.items);
    typeError("unsupported operand types for +");
}

private Value mul(Value a, Value b)
{
    if (a.isNumber && b.isNumber)
        return arith(a, b, "*", (x, y) => x * y, (x, y) => x * y);
    if (a.kind == Kind.text && b.isIntegral)
        return Value.text(repeatText(a.s, b.i));
    if (a.isIntegral && b.kind == Kind.text)
        return Value.text(repeatText(b.s, a.i));
    typeError("unsupported operand types for *");
}

private string repeatText(string s, long n)
{
    if (n <= 0 || s.length == 0)
        return "";
    return replicate(s, cast(size_t) n);
}

private Value divide(Value a, Value b)
{
    if (!a.isNumber || !b.isNumber)
        typeError("unsupported operand types for /");
    const y = b.asDouble;
    if (y == 0)
        typeError("division by zero");
    return Value.floating(a.asDouble / y);
}

private Value floorDivide(Value a, Value b)
{
    if (!a.isNumber || !b.isNumber)
        typeError("unsupported operand types for //");
    if (a.kind != Kind.floating && b.kind != Kind.floating)
    {
        if (b.i == 0)
            typeError("integer division by zero");
        if (b.i == -1)
            return Value.integer(-a.i);
        long q = a.i / b.i;
        if ((a.i % b.i != 0) && ((a.i < 0) != (b.i < 0)))
            --q;
        return Value.integer(q);
    }
    const x = a.asDouble, y = b.asDouble;
    if (y == 0)
        typeError("float floor division by zero");
    double mod = fmod(x, y);
    double div = (x - mod) / y;
    if (mod != 0 && ((y < 0) != (mod < 0)))
        div -= 1.0;
    double result;
    if (div != 0)
    {
        result = floor(div);
        if (div - result > 0.5)
            result += 1.0;
    }
    else
        result = copysign(0.0, x / y);
    return Value.floating(result);
}

private Value modulo(Value a, Value b)
{
    if (!a.isNumber || !b.isNumber)
        typeError("unsupported operand types for %");
    if (a.kind != Kind.floating && b.kind != Kind.floating)
    {
        if (b.i == 0)
            typeError("integer modulo by zero");
        if (b.i == -1)
            return Value.integer(0);
        long r = a.i % b.i;
        if (r != 0 && ((r < 0) != (b.i < 0)))
            r += b.i;
        return Value.integer(r);
    }
    const x = a.asDouble, y = b.asDouble;
    if (y == 0)
        typeError("float modulo by zero");
    double mod = fmod(x, y);
    if (mod != 0)
    {
        if ((y < 0) != (mod < 0))
            mod += y;
    }
    else
        mod = copysign(0.0, y);
    return Value.floating(mod);
}

private Value power(Value a, Value b)
{
    if (!a.isNumber || !b.isNumber)
        typeError("unsupported operand types for **");
    if (a.kind != Kind.floating && b.kind != Kind.floating && b.i >= 0)
    {
        long result = 1, base = a.i, e = b.i;
        while (e > 0)
        {
            if (e & 1)
                result *= base;
            base *= base;
            e >>= 1;
        }
        return Value.integer(result);
    }
    const x = a.asDouble, y = b.asDouble;
    if (x == 0 && y < 0)
        typeError("zero raised to a negative power");
    return Value.floating(pow(x, y));
}

/// Unary minus.
Value negate(Value v)
{
    requireDefined(v);
    if (v.kind == Kind.floating)
        return Value.floating(-v.d);
    if (v.isIntegral)
        return Value.integer(-v.i);
    typeError("bad operand type for unary -");
}

/// Evaluate one comparison; the result is always a bool.
bool compare(CmpOp op, Value a, Value b)
{
    requireBothDefined(a, b);
    final switch (op)
    {
    case CmpOp.eq: return valuesEqual(a, b);
    case CmpOp.ne: return !valuesEqual(a, b);
    case CmpOp.lt: return order(a, b) < 0;
    case CmpOp.le: return order(a, b) <= 0;
    case CmpOp.gt: return order(a, b) > 0;
    case CmpOp.ge: return order(a, b) >= 0;
    case CmpOp.in_: return contains(b, a);
    case CmpOp.notIn: return !contains(b, a);
    }
}

private int order(Value a, Value b)
{
    if (a.isNumber && b.isNumber)
    {
        if (a.kind != Kind.floating && b.kind != Kind.floating)
            return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
        const x = a.asDouble, y = b.asDouble;
        return x < y ? -1 : (x > y ? 1 : 0);
    }
    if (a.kind == Kind.text && b.kind == Kind.text)
        return compareText(a.s, b.s);
    typeError("values cannot be ordered");
}

/// `needle in haystack`.
bool contains(Value haystack, Value needle)
{
    switch (haystack.kind)
    {
    case Kind.text:
        if (needle.kind != Kind.text)
            typeError("'in <string>' requires a string as left operand");
        return needle.s.length == 0 || indexOf(haystack.s, needle.s) >= 0;
    case Kind.dict:
        return needle.kind == Kind.text && haystack.asDict.find(needle.s) !is null;
    case Kind.list:
        foreach (item; haystack.items)
            if (valuesEqual(item, needle))
                return true;
        return false;
    default:
        typeError("argument of type is not iterable");
    }
}

/// `a[key]` and `a.key`: a miss yields the undefined value; undefined operands are errors.
Value getItem(Value a, Value key)
{
    requireDefined(a, "attribute or subscript access on an undefined value");
    requireDefined(key, "undefined subscript key");
    switch (a.kind)
    {
    case Kind.dict:
        if (key.kind == Kind.text)
            if (auto p = a.asDict.find(key.s))
                return *p;
        return Value.undefined;
    case Kind.list:
    {
        if (!key.isIntegral)
            return Value.undefined;
        auto items = a.items;
        long idx = key.i;
        if (idx < 0)
            idx += cast(long) items.length;
        if (idx < 0 || idx >= cast(long) items.length)
            return Value.undefined;
        return items[cast(size_t) idx];
    }
    case Kind.text:
    {
        if (!key.isIntegral)
            return Value.undefined;
        return charAt(a.s, key.i);
    }
    case Kind.loop:
    {
        if (key.kind != Kind.text)
            return Value.undefined;
        auto info = cast(LoopInfo) a.obj;
        switch (key.s)
        {
        case "index":  return Value.integer(info.index0 + 1);
        case "index0": return Value.integer(info.index0);
        case "first":  return Value.boolean(info.index0 == 0);
        case "last":   return Value.boolean(info.index0 + 1 == info.length);
        case "length": return Value.integer(info.length);
        default:       return Value.undefined;
        }
    }
    default:
        return Value.undefined;
    }
}

/// The one-character string at code point index `idx` (negative counts from the end).
private Value charAt(string s, long idx)
{
    if (idx < 0)
    {
        idx += cast(long) codePointCount(s);
        if (idx < 0)
            return Value.undefined;
    }
    size_t pos = 0;
    foreach (_; 0 .. cast(size_t) idx)
    {
        if (pos >= s.length)
            return Value.undefined;
        pos += utf8Length(s[pos]);
    }
    if (pos >= s.length)
        return Value.undefined;
    const len = utf8Length(s[pos]);
    return Value.text(s[pos .. pos + len]);
}

/++
    The sequence view of a value: a list is its elements, a dict its keys, a
    string its one-character strings. Anything else is a `type` error.
+/
Value[] sequenceView(Value v)
{
    switch (v.kind)
    {
    case Kind.undefined:
        undefinedError("iterating an undefined value");
    case Kind.list:
        return v.items;
    case Kind.dict:
    {
        auto d = v.asDict;
        auto result = new Value[d.length];
        foreach (idx, key; d.keys)
            result[idx] = Value.text(key);
        return result;
    }
    case Kind.text:
    {
        auto result = new Value[codePointCount(v.s)];
        size_t pos = 0;
        foreach (ref slot; result)
        {
            const len = utf8Length(v.s[pos]);
            slot = Value.text(v.s[pos .. pos + len]);
            pos += len;
        }
        return result;
    }
    default:
        typeError("value is not iterable");
    }
}

version (unittest)
{
    private Value I(long n) { return Value.integer(n); }
    private Value F(double x) { return Value.floating(x); }
    private Value T(string s) { return Value.text(s); }
}

unittest
{
    assert(binaryOp(BinOp.add, I(1), I(2)).i == 3);
    assert(binaryOp(BinOp.add, I(1), F(2)).d == 3.0);
    assert(binaryOp(BinOp.add, Value.boolean(true), Value.boolean(true)).i == 2);
    assert(binaryOp(BinOp.add, T("a"), T("b")).s == "ab");
    assert(binaryOp(BinOp.mul, T("ab"), I(2)).s == "abab");
    assert(binaryOp(BinOp.mul, I(-1), T("ab")).s == "");
    assert(binaryOp(BinOp.div, I(6), I(3)).d == 2.0);
    assert(binaryOp(BinOp.floorDiv, I(-7), I(2)).i == -4);
    assert(binaryOp(BinOp.floorDiv, F(7.0), I(2)).d == 3.0);
    assert(binaryOp(BinOp.mod, I(-7), I(3)).i == 2);
    assert(binaryOp(BinOp.mod, I(7), I(-3)).i == -2);
    assert(binaryOp(BinOp.pow, I(2), I(10)).i == 1024);
    assert(binaryOp(BinOp.pow, I(2), I(-1)).d == 0.5);
    assert(toStr(binaryOp(BinOp.concat, I(1), T("x"))) == "1x");
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!TemplateError(binaryOp(BinOp.add, T("a"), I(1)));
    assertThrown!TemplateError(binaryOp(BinOp.div, I(1), I(0)));
    assertThrown!TemplateError(binaryOp(BinOp.mod, I(1), I(0)));
    assertThrown!TemplateError(binaryOp(BinOp.pow, I(0), I(-1)));
    assertThrown!TemplateError(binaryOp(BinOp.add, Value.undefined, I(1)));
    assertThrown!TemplateError(compare(CmpOp.lt, T("a"), I(1)));
}

unittest
{
    assert(compare(CmpOp.in_, T("b"), T("abc")));
    assert(compare(CmpOp.in_, T(""), T("abc")));
    assert(compare(CmpOp.notIn, I(3), Value.list([I(1), I(2)])));
    assert(compare(CmpOp.lt, T("ab"), T("abc")));
    assert(compare(CmpOp.eq, I(1), F(1.0)));
    assert(getItem(Value.list([I(1), I(2)]), I(-1)).i == 2);
    assert(getItem(Value.list([I(1), I(2)]), I(2)).isUndefined);
    assert(getItem(T("héy"), I(1)).s == "é");
    assert(getItem(T("héy"), I(-1)).s == "y");
    assert(getItem(Value.none, T("x")).isUndefined);
    assert(sequenceView(T("hé")).length == 2);
}

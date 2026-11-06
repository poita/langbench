/// Operators and the small semantic helpers shared by the interpreter and
/// the filters: truthiness, arithmetic, comparison, equality, membership,
/// attribute / subscript access and sequence views.
module jtemplate.ops;

import core.stdc.math : floor, fmod, pow, copysign;

import jtemplate.ast : BinOp, CmpOp;
import jtemplate.buffer;
import jtemplate.errors;
import jtemplate.format;
import jtemplate.value;

// ---------------------------------------------------------------------------
// UTF-8 helpers
// ---------------------------------------------------------------------------

/// Length in bytes of the UTF-8 sequence that starts with byte `lead`.
size_t utf8Stride(char lead) pure nothrow @safe @nogc
{
    if (lead < 0x80) return 1;
    if (lead < 0xE0) return 2;
    if (lead < 0xF0) return 3;
    return 4;
}

/// Number of code points in `s`.
size_t codePointCount(const(char)[] s) pure nothrow @safe @nogc
{
    size_t n = 0;
    foreach (c; s)
        if ((c & 0xC0) != 0x80) ++n;
    return n;
}

// ---------------------------------------------------------------------------
// Truthiness
// ---------------------------------------------------------------------------

/// Truthiness of a value. Throws an `undefined` error for undefined.
bool truthy(Value v) @trusted
{
    final switch (v.kind)
    {
        case Kind.undefined:
        case Kind.unset:
            throw undefinedError("truth value of an undefined value");
        case Kind.none:     return false;
        case Kind.boolean:
        case Kind.integer:  return v.i != 0;
        case Kind.floating: return v.d != 0.0;
        case Kind.str:      return v.s.length != 0;
        case Kind.list:     return v.list.length != 0;
        case Kind.dict:     return v.dict.length != 0;
        case Kind.macro_:
        case Kind.rangeFn:
        case Kind.superFn:
        case Kind.loop:     return true;
    }
}

// ---------------------------------------------------------------------------
// Sequence view
// ---------------------------------------------------------------------------

/// The sequence view of a value: a list's elements (shared, not copied), a
/// dict's keys, or a string's characters. Anything else is a `type` error
/// (`undefined` for the undefined value).
Value[] sequenceView(Value v) @trusted
{
    switch (v.kind)
    {
        case Kind.list:
            return cast(Value[]) v.list;
        case Kind.dict:
        {
            auto out_ = new Value[v.dict.length];
            foreach (i, k; v.dict.keys)
                out_[i] = Value.fromString(k);
            return out_;
        }
        case Kind.str:
        {
            Value[] out_;
            out_.reserve(v.s.length);
            size_t i = 0;
            while (i < v.s.length)
            {
                immutable n = utf8Stride(v.s[i]);
                out_ ~= Value.fromString(v.s[i .. i + n]);
                i += n;
            }
            return out_;
        }
        case Kind.undefined:
        case Kind.unset:
            throw undefinedError("iterating the undefined value");
        default:
            throw typeError("value is not a sequence");
    }
}

// ---------------------------------------------------------------------------
// Attribute / subscript access
// ---------------------------------------------------------------------------

/// `a.key` / `a[key]`.
Value getItem(Value a, Value key) @trusted
{
    if (a.kind == Kind.undefined || key.kind == Kind.undefined)
        throw undefinedError("subscript of an undefined value");
    switch (a.kind)
    {
        case Kind.dict:
            if (key.kind == Kind.str)
                if (auto p = a.dict.find(key.s))
                    return *p;
            return Value.undef;
        case Kind.list:
            if (key.isIntegral)
            {
                long i = key.i;
                immutable n = cast(long) a.list.length;
                if (i < 0) i += n;
                if (i >= 0 && i < n)
                    return a.list[cast(size_t) i];
            }
            return Value.undef;
        case Kind.str:
            if (key.isIntegral)
                return charAt(a.s, key.i);
            return Value.undef;
        case Kind.loop:
            if (key.kind == Kind.str)
            {
                switch (key.s)
                {
                    case "index":  return Value.fromInt(a.i + 1);
                    case "index0": return Value.fromInt(a.i);
                    case "first":  return Value.fromBool(a.i == 0);
                    case "last":   return Value.fromBool(a.i + 1 == a.aux);
                    case "length": return Value.fromInt(a.aux);
                    default: break;
                }
            }
            return Value.undef;
        default:
            return Value.undef;
    }
}

private Value charAt(string s, long i) pure nothrow @trusted
{
    if (i >= 0)
    {
        size_t pos = 0;
        long k = 0;
        while (pos < s.length)
        {
            immutable n = utf8Stride(s[pos]);
            if (k == i)
                return Value.fromString(s[pos .. pos + n]);
            pos += n;
            ++k;
        }
        return Value.undef;
    }
    // negative: walk back from the end
    size_t end = s.length;
    long k = -1;
    while (end > 0)
    {
        size_t start = end - 1;
        while (start > 0 && (s[start] & 0xC0) == 0x80) --start;
        if (k == i)
            return Value.fromString(s[start .. end]);
        end = start;
        --k;
    }
    return Value.undef;
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

private void checkDefined(Value a, Value b) pure @safe
{
    if (a.kind == Kind.undefined || b.kind == Kind.undefined)
        throw undefinedError("operand is undefined");
}

/// Unary minus.
Value negate(Value a) @trusted
{
    switch (a.kind)
    {
        case Kind.integer:
        case Kind.boolean:  return Value.fromInt(-a.i);
        case Kind.floating: return Value.fromFloat(-a.d);
        case Kind.undefined: throw undefinedError("operand is undefined");
        default: throw typeError("bad operand for unary -");
    }
}

/// Apply a binary arithmetic / concatenation operator.
Value binaryOp(BinOp op, Value a, Value b) @trusted
{
    // fast path: two integers
    if (a.kind == Kind.integer && b.kind == Kind.integer)
    {
        switch (op)
        {
            case BinOp.add: return Value.fromInt(a.i + b.i);
            case BinOp.sub: return Value.fromInt(a.i - b.i);
            case BinOp.mul: return Value.fromInt(a.i * b.i);
            default: break;
        }
    }
    checkDefined(a, b);
    final switch (op)
    {
        case BinOp.add:
            if (a.isNumber && b.isNumber)
                return a.kind == Kind.floating || b.kind == Kind.floating
                    ? Value.fromFloat(a.asDouble + b.asDouble)
                    : Value.fromInt(a.i + b.i);
            if (a.kind == Kind.str && b.kind == Kind.str)
                return Value.fromString(a.s ~ b.s);
            if (a.kind == Kind.list && b.kind == Kind.list)
                return Value.fromList(cast(Value[])(a.list ~ b.list));
            throw typeError("unsupported operands for +");
        case BinOp.sub:
            if (a.isNumber && b.isNumber)
                return a.kind == Kind.floating || b.kind == Kind.floating
                    ? Value.fromFloat(a.asDouble - b.asDouble)
                    : Value.fromInt(a.i - b.i);
            throw typeError("unsupported operands for -");
        case BinOp.mul:
            if (a.isNumber && b.isNumber)
                return a.kind == Kind.floating || b.kind == Kind.floating
                    ? Value.fromFloat(a.asDouble * b.asDouble)
                    : Value.fromInt(a.i * b.i);
            if (a.kind == Kind.str && b.isIntegral)
                return Value.fromString(repeat(a.s, b.i));
            if (a.isIntegral && b.kind == Kind.str)
                return Value.fromString(repeat(b.s, a.i));
            throw typeError("unsupported operands for *");
        case BinOp.div:
            if (!(a.isNumber && b.isNumber)) throw typeError("unsupported operands for /");
            if (b.asDouble == 0) throw typeError("division by zero");
            return Value.fromFloat(a.asDouble / b.asDouble);
        case BinOp.floorDiv:
            if (!(a.isNumber && b.isNumber)) throw typeError("unsupported operands for //");
            if (b.asDouble == 0) throw typeError("division by zero");
            if (a.kind != Kind.floating && b.kind != Kind.floating)
                return Value.fromInt(floorDivInt(a.i, b.i));
            return Value.fromFloat(floatDivMod(a.asDouble, b.asDouble).div);
        case BinOp.mod:
            if (!(a.isNumber && b.isNumber)) throw typeError("unsupported operands for %");
            if (b.asDouble == 0) throw typeError("modulo by zero");
            if (a.kind != Kind.floating && b.kind != Kind.floating)
                return Value.fromInt(modInt(a.i, b.i));
            return Value.fromFloat(floatDivMod(a.asDouble, b.asDouble).mod);
        case BinOp.pow:
            if (!(a.isNumber && b.isNumber)) throw typeError("unsupported operands for **");
            return power(a, b);
        case BinOp.concat:
            return Value.fromString(toStr(a) ~ toStr(b));
    }
}

private string repeat(string s, long n) pure nothrow @trusted
{
    if (n <= 0 || s.length == 0) return "";
    if (n == 1) return s;
    auto buf = new char[s.length * cast(size_t) n];
    foreach (k; 0 .. cast(size_t) n)
        buf[k * s.length .. (k + 1) * s.length] = s[];
    return cast(string) buf;
}

private long floorDivInt(long a, long b) pure nothrow @safe @nogc
{
    if (b == -1) return -a;
    long q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
    return q;
}

private long modInt(long a, long b) pure nothrow @safe @nogc
{
    if (b == -1) return 0;
    long r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) r += b;
    return r;
}

private struct DivMod { double div; double mod; }

/// Python's float divmod.
private DivMod floatDivMod(double a, double b) nothrow @trusted @nogc
{
    double mod = fmod(a, b);
    double div = (a - mod) / b;
    if (mod != 0)
    {
        if ((b < 0) != (mod < 0))
        {
            mod += b;
            div -= 1.0;
        }
    }
    else
        mod = copysign(0.0, b);
    double fd;
    if (div != 0)
    {
        fd = floor(div);
        if (div - fd > 0.5) fd += 1.0;
    }
    else
        fd = copysign(0.0, a / b);
    return DivMod(fd, mod);
}

private Value power(Value a, Value b) @trusted
{
    if (a.kind != Kind.floating && b.kind != Kind.floating)
    {
        if (b.i >= 0)
        {
            long result = 1, base = a.i;
            long e = b.i;
            while (e > 0)
            {
                if (e & 1) result *= base;
                e >>= 1;
                if (e) base *= base;
            }
            return Value.fromInt(result);
        }
        if (a.i == 0) throw typeError("0 cannot be raised to a negative power");
        return Value.fromFloat(pow(cast(double) a.i, cast(double) b.i));
    }
    immutable x = a.asDouble, y = b.asDouble;
    if (x == 0 && y < 0) throw typeError("0 cannot be raised to a negative power");
    return Value.fromFloat(pow(x, y));
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

/// `==` on two defined values (never throws except for undefined operands).
bool valuesEqual(Value a, Value b) @trusted
{
    if (a.kind == Kind.undefined || b.kind == Kind.undefined
        || a.kind == Kind.unset || b.kind == Kind.unset)
        throw undefinedError("comparing an undefined value");
    return equalDefined(a, b);
}

private bool equalDefined(Value a, Value b) @trusted
{
    if (a.isNumber && b.isNumber)
    {
        if (a.kind != Kind.floating && b.kind != Kind.floating)
            return a.i == b.i;
        return a.asDouble == b.asDouble;
    }
    if (a.kind != b.kind)
        return false;
    switch (a.kind)
    {
        case Kind.none: return true;
        case Kind.str:  return a.s.length == b.s.length && a.s == b.s;
        case Kind.list:
        {
            if (a.list.length != b.list.length) return false;
            if (a.list.ptr is b.list.ptr) return true;
            foreach (i; 0 .. a.list.length)
                if (!equalDefined(a.list[i], b.list[i]))
                    return false;
            return true;
        }
        case Kind.dict:
        {
            if (a.dict is b.dict) return true;
            if (a.dict.length != b.dict.length) return false;
            foreach (i, k; a.dict.keys)
            {
                auto p = b.dict.find(k);
                if (p is null || !equalDefined(a.dict.vals[i], *p))
                    return false;
            }
            return true;
        }
        case Kind.macro_:   return a.mac is b.mac;
        case Kind.rangeFn: return true;
        default:           return false;
    }
}

/// Three-way comparison for `<`, `<=`, `>`, `>=`: negative, zero or positive.
int compareValues(Value a, Value b) @trusted
{
    checkDefined(a, b);
    if (a.isNumber && b.isNumber)
    {
        if (a.kind != Kind.floating && b.kind != Kind.floating)
            return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
        immutable x = a.asDouble, y = b.asDouble;
        return x < y ? -1 : (x > y ? 1 : 0);
    }
    if (a.kind == Kind.str && b.kind == Kind.str)
    {
        import core.stdc.string : memcmp;
        immutable n = a.s.length < b.s.length ? a.s.length : b.s.length;
        immutable c = n ? memcmp(a.s.ptr, b.s.ptr, n) : 0;
        if (c != 0) return c < 0 ? -1 : 1;
        return a.s.length < b.s.length ? -1 : (a.s.length > b.s.length ? 1 : 0);
    }
    throw typeError("values cannot be ordered");
}

/// Evaluate one comparison operator on two evaluated operands.
bool compareOp(CmpOp op, Value a, Value b) @trusted
{
    final switch (op)
    {
        case CmpOp.eq:    return valuesEqual(a, b);
        case CmpOp.ne:    return !valuesEqual(a, b);
        case CmpOp.lt:    return compareValues(a, b) < 0;
        case CmpOp.le:    return compareValues(a, b) <= 0;
        case CmpOp.gt:    return compareValues(a, b) > 0;
        case CmpOp.ge:    return compareValues(a, b) >= 0;
        case CmpOp.in_:   return contains(b, a);
        case CmpOp.notIn: return !contains(b, a);
    }
}

/// `needle in haystack`.
bool contains(Value haystack, Value needle) @trusted
{
    checkDefined(haystack, needle);
    switch (haystack.kind)
    {
        case Kind.str:
        {
            if (needle.kind != Kind.str) throw typeError("'in <string>' requires a string");
            import std.string : indexOf;
            if (needle.s.length == 0) return true;
            return haystack.s.indexOf(needle.s) >= 0;
        }
        case Kind.dict:
            return needle.kind == Kind.str && haystack.dict.find(needle.s) !is null;
        case Kind.list:
            foreach (ref e; haystack.list)
                if (equalDefined(e, needle))
                    return true;
            return false;
        default:
            throw typeError("argument of type is not iterable");
    }
}

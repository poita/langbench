/**
 * The values manipulated by templates.
 *
 * A $(LREF Value) is a small tagged struct.  Lists and dicts are shared by
 * reference and never mutated after construction, so copying a value, binding
 * it to a name or passing it to a macro costs O(1) whatever its size.
 */
module sitegen.templating.value;

import std.array : Appender, appender;
import sitegen.templating.errors;

/// The kinds of value.
enum Kind : ubyte
{
    /// The undefined value (a missing name or member).
    undefined,
    none,
    boolean,
    integer,
    floating,
    string_,
    list,
    dict,
    /// A macro, `super` or `range`.
    callable,
    /// The `loop` object of a `for` body.
    loop,
}

/// An insertion-ordered mapping from strings to values.
final class Dict
{
    private string[] keys_;
    private Value[string] map_;

    /// Creates an empty dict.
    this() {}

    /// Sets `key`, appending it to the order if it is new.
    Dict set(string key, Value value)
    {
        if (key !in map_) keys_ ~= key;
        map_[key] = value;
        return this;
    }

    /// Looks `key` up; returns whether it is present.
    bool get(string key, out Value value) const
    {
        if (auto p = key in map_)
        {
            value = cast(Value) *p;
            return true;
        }
        return false;
    }

    /// Whether `key` is present.
    bool contains(string key) const
    {
        return (key in map_) !is null;
    }

    /// The keys, in insertion order.
    @property const(string)[] keys() const
    {
        return keys_;
    }

    /// The number of members.
    @property size_t length() const
    {
        return keys_.length;
    }
}

/// Something that can be called from a template.
abstract class Callable
{
}

/// A template value.
struct Value
{
    Kind kind;
    /// The payload of integers and booleans (0 or 1), and the zero-based
    /// index of a `loop` object.
    long i;
    /// The payload of floats.
    double f;
    /// The payload of strings.
    string s;
    /// The payload of lists.
    Value[] l;
    /// The payload of dicts.
    Dict d;
    /// The payload of callables.
    Callable c;
    /// The length of the sequence a `loop` object iterates over.
    long loopLength;

    /// The undefined value.
    static Value undefined()
    {
        return Value.init;
    }

    /// `none`.
    static Value none()
    {
        Value v;
        v.kind = Kind.none;
        return v;
    }

    /// A boolean.
    static Value boolean(bool b)
    {
        Value v;
        v.kind = Kind.boolean;
        v.i = b;
        return v;
    }

    /// An integer.
    static Value integer(long n)
    {
        Value v;
        v.kind = Kind.integer;
        v.i = n;
        return v;
    }

    /// A float.
    static Value floating(double x)
    {
        Value v;
        v.kind = Kind.floating;
        v.f = x;
        return v;
    }

    /// A string.
    static Value str(string s)
    {
        Value v;
        v.kind = Kind.string_;
        v.s = s;
        return v;
    }

    /// A list.  The elements are not copied: do not modify them afterwards.
    static Value list(Value[] items)
    {
        Value v;
        v.kind = Kind.list;
        v.l = items;
        return v;
    }

    /// A list of strings.
    static Value list(const(string)[] items)
    {
        auto vs = new Value[items.length];
        foreach (idx, s; items) vs[idx] = str(s.idup);
        return list(vs);
    }

    /// A dict.
    static Value dict(Dict d)
    {
        Value v;
        v.kind = Kind.dict;
        v.d = d;
        return v;
    }

    /// A callable.
    static Value callable(Callable c)
    {
        Value v;
        v.kind = Kind.callable;
        v.c = c;
        return v;
    }

    /// Whether this is the undefined value.
    @property bool isUndefined() const
    {
        return kind == Kind.undefined;
    }

    /// Whether this is an integer, a float or a boolean.
    @property bool isNumber() const
    {
        return kind == Kind.integer || kind == Kind.floating || kind == Kind.boolean;
    }

    /// Whether this is an integer or a boolean.
    @property bool isIntegral() const
    {
        return kind == Kind.integer || kind == Kind.boolean;
    }

    /// This number as a double.
    double asDouble() const
    {
        return kind == Kind.floating ? f : cast(double) i;
    }
}

/// Whether `v` is truthy.  Testing the undefined value is an error.
bool truthy(const Value v)
{
    final switch (v.kind)
    {
        case Kind.undefined:
            undefinedError("the undefined value has no truth value");
        case Kind.none:
            return false;
        case Kind.boolean, Kind.integer:
            return v.i != 0;
        case Kind.floating:
            return v.f != 0.0;
        case Kind.string_:
            return v.s.length != 0;
        case Kind.list:
            return v.l.length != 0;
        case Kind.dict:
            return v.d.length != 0;
        case Kind.callable, Kind.loop:
            return true;
    }
}

/// Equality as defined by the `==` operator.  Neither operand may be undefined.
bool valuesEqual(const Value a, const Value b)
{
    if (a.isNumber && b.isNumber)
    {
        if (a.isIntegral && b.isIntegral) return a.i == b.i;
        return a.asDouble == b.asDouble;
    }
    if (a.kind != b.kind) return false;
    switch (a.kind)
    {
        case Kind.none:
            return true;
        case Kind.string_:
            return a.s == b.s;
        case Kind.list:
            if (a.l.length != b.l.length) return false;
            foreach (idx; 0 .. a.l.length)
                if (!valuesEqual(a.l[idx], b.l[idx])) return false;
            return true;
        case Kind.dict:
            if (a.d.length != b.d.length) return false;
            foreach (k; a.d.keys)
            {
                Value x, y;
                if (!b.d.get(k, y)) return false;
                a.d.get(k, x);
                if (!valuesEqual(x, y)) return false;
            }
            return true;
        case Kind.callable:
            return a.c is b.c;
        default:
            return false;
    }
}

/// The sequence view of a value: a list's elements, a dict's keys or a
/// string's characters.  Other values are a `type` error.
Value[] sequenceOf(const Value v)
{
    switch (v.kind)
    {
        case Kind.list:
            return cast(Value[]) v.l;
        case Kind.dict:
            {
                auto r = new Value[v.d.length];
                foreach (idx, k; v.d.keys) r[idx] = Value.str(k);
                return r;
            }
        case Kind.string_:
            {
                Value[] r;
                size_t i = 0;
                while (i < v.s.length)
                {
                    const n = utf8Length(v.s[i]);
                    const end = i + n > v.s.length ? v.s.length : i + n;
                    r ~= Value.str(v.s[i .. end]);
                    i = end;
                }
                return r;
            }
        case Kind.undefined:
            undefinedError("the undefined value is not a sequence");
        default:
            typeError("value is not a sequence");
    }
}

/// The number of bytes of the UTF-8 sequence introduced by `lead`.
size_t utf8Length(char lead) pure nothrow @nogc @safe
{
    if (lead < 0xC0) return 1;
    if (lead < 0xE0) return 2;
    if (lead < 0xF0) return 3;
    return 4;
}

/// The number of Unicode code points in `s`.
size_t codePointCount(string s) pure nothrow @nogc @safe
{
    size_t n = 0;
    foreach (char c; s)
        if ((c & 0xC0) != 0x80) n++;
    return n;
}

/// Parses a decimal floating-point literal with correct rounding.
double parseDouble(string s)
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    return strtod(s.toStringz, null);
}

/**
 * Formats a float as Python's `repr` does: the shortest digit string that
 * round-trips, in positional notation for decimal exponents in [-4, 16) and
 * in scientific notation otherwise.
 */
string formatFloat(double v)
{
    import std.format : format;
    import std.math : isNaN, isInfinity, signbit;
    import std.conv : to;

    if (isNaN(v)) return "nan";
    if (isInfinity(v)) return v < 0 ? "-inf" : "inf";
    if (v == 0) return signbit(v) ? "-0.0" : "0.0";

    string digits;
    int exponent;
    foreach (prec; 1 .. 18)
    {
        const s = format("%.*e", prec - 1, v < 0 ? -v : v);
        if (prec == 17 || parseDouble(s) == (v < 0 ? -v : v))
        {
            // s looks like d.ddde+XX
            size_t e = 0;
            while (s[e] != 'e') e++;
            Appender!string ds;
            foreach (c; s[0 .. e])
                if (c != '.') ds.put(c);
            digits = ds.data;
            exponent = s[e + 1 .. $].to!int;
            break;
        }
    }
    auto o = appender!string();
    if (v < 0) o.put('-');
    if (exponent >= -4 && exponent < 16)
    {
        if (exponent >= 0)
        {
            const intLen = cast(size_t) exponent + 1;
            foreach (idx; 0 .. intLen) o.put(idx < digits.length ? digits[idx] : '0');
            o.put('.');
            if (digits.length > intLen)
                o.put(digits[intLen .. $]);
            else
                o.put('0');
        }
        else
        {
            o.put("0.");
            foreach (_; 0 .. -exponent - 1) o.put('0');
            o.put(digits);
        }
    }
    else
    {
        o.put(digits[0]);
        if (digits.length > 1)
        {
            o.put('.');
            o.put(digits[1 .. $]);
        }
        o.put('e');
        o.put(exponent < 0 ? '-' : '+');
        const ae = exponent < 0 ? -exponent : exponent;
        if (ae < 10) o.put('0');
        o.put(ae.to!string);
    }
    return o.data;
}

private void putRepr(ref Appender!string o, const Value v)
{
    if (v.kind == Kind.string_)
    {
        import std.algorithm.searching : canFind;

        const useDouble = v.s.canFind('\'') && !v.s.canFind('"');
        const q = useDouble ? '"' : '\'';
        o.put(q);
        foreach (char c; v.s)
        {
            if (c == '\\')
                o.put("\\\\");
            else if (c == '\n')
                o.put("\\n");
            else if (c == '\r')
                o.put("\\r");
            else if (c == '\t')
                o.put("\\t");
            else if (c == q)
            {
                o.put('\\');
                o.put(c);
            }
            else
                o.put(c);
        }
        o.put(q);
    }
    else
        putString(o, v);
}

private void putString(ref Appender!string o, const Value v)
{
    import std.conv : to;

    final switch (v.kind)
    {
        case Kind.undefined:
            undefinedError("the undefined value cannot be converted to a string");
        case Kind.none:
            o.put("None");
            break;
        case Kind.boolean:
            o.put(v.i ? "True" : "False");
            break;
        case Kind.integer:
            o.put(v.i.to!string);
            break;
        case Kind.floating:
            o.put(formatFloat(v.f));
            break;
        case Kind.string_:
            o.put(v.s);
            break;
        case Kind.list:
            o.put('[');
            foreach (idx, e; v.l)
            {
                if (idx) o.put(", ");
                putRepr(o, e);
            }
            o.put(']');
            break;
        case Kind.dict:
            o.put('{');
            foreach (idx, k; v.d.keys)
            {
                if (idx) o.put(", ");
                putRepr(o, Value.str(k));
                o.put(": ");
                Value x;
                v.d.get(k, x);
                putRepr(o, x);
            }
            o.put('}');
            break;
        case Kind.callable:
            o.put("<macro>");
            break;
        case Kind.loop:
            o.put("<loop>");
            break;
    }
}

/// The string form of a value, as printed by `{{ }}`.
string toDisplay(const Value v)
{
    if (v.kind == Kind.string_) return v.s;
    auto o = appender!string();
    putString(o, v);
    return o.data;
}

/// Appends the string form of `v` to `o`.
void appendDisplay(ref Appender!string o, const Value v)
{
    if (v.kind == Kind.string_)
        o.put(v.s);
    else
        putString(o, v);
}

unittest
{
    assert(formatFloat(3.0) == "3.0");
    assert(formatFloat(0.5) == "0.5");
    assert(formatFloat(1000000000000000.0) == "1000000000000000.0");
    assert(formatFloat(0.0001) == "0.0001");
    assert(formatFloat(0.1 + 0.2) == "0.30000000000000004");
    assert(formatFloat(1e16) == "1e+16");
    assert(formatFloat(1e-5) == "1e-05");
    assert(formatFloat(1.5e300) == "1.5e+300");
    assert(formatFloat(-0.0) == "-0.0");
    assert(formatFloat(-2.5) == "-2.5");
    assert(formatFloat(123456.789) == "123456.789");
}

unittest
{
    auto d = new Dict;
    d.set("k", Value.list([Value.floating(2.0)]));
    auto l = Value.list([Value.integer(1), Value.str("a"), Value.boolean(true), Value.none(),
            Value.floating(1.5), Value.str("it's"), Value.dict(d)]);
    assert(toDisplay(l) == `[1, 'a', True, None, 1.5, "it's", {'k': [2.0]}]`);
    assert(toDisplay(Value.list(cast(Value[])[])) == "[]");
}

unittest
{
    assert(valuesEqual(Value.integer(1), Value.floating(1.0)));
    assert(valuesEqual(Value.boolean(true), Value.integer(1)));
    assert(!valuesEqual(Value.integer(1), Value.str("1")));
    assert(!valuesEqual(Value.none(), Value.integer(0)));
    assert(codePointCount("aé€") == 3);
}

/**
 * KBL values: `bool`, `int`, `str` and `list`, with their total order and
 * deep structural equality.
 */
module kiln.value;

import kiln.bytes : cmpBytes, decimal;

/// The four KBL types, declared in the order of the cross-type ordering.
enum ValueType : ubyte
{
    boolean,
    integer,
    str,
    list,
}

/// A KBL value. Copying is O(1): strings and lists are shared slices.
struct Value
{
    ValueType type;
    long i; // int payload, or 0/1 for bool
    string s; // str payload
    Value[] l; // list payload

    /// An `int` value.
    static Value ofInt(long v) @safe pure nothrow @nogc
    {
        Value r;
        r.type = ValueType.integer;
        r.i = v;
        return r;
    }

    /// A `bool` value.
    static Value ofBool(bool v) @safe pure nothrow @nogc
    {
        Value r;
        r.type = ValueType.boolean;
        r.i = v ? 1 : 0;
        return r;
    }

    /// A `str` value.
    static Value ofStr(string v) @safe pure nothrow @nogc
    {
        Value r;
        r.type = ValueType.str;
        r.s = v;
        return r;
    }

    /// A `list` value.
    static Value ofList(Value[] v) @safe pure nothrow @nogc
    {
        Value r;
        r.type = ValueType.list;
        r.l = v;
        return r;
    }

    /// A list of strings.
    static Value ofStrings(const(string)[] v) @safe pure nothrow
    {
        auto items = new Value[v.length];
        foreach (k, x; v)
            items[k] = ofStr(x);
        return ofList(items);
    }

    /// The `bool` payload.
    bool asBool() const @safe pure nothrow @nogc
    {
        return i != 0;
    }
}

/// The type token of a value: `bool`, `int`, `str` or `list`.
string typeName(ValueType t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ValueType.boolean:
        return "bool";
    case ValueType.integer:
        return "int";
    case ValueType.str:
        return "str";
    case ValueType.list:
        return "list";
    }
}

/// ditto
string typeName(in Value v) @safe pure nothrow @nogc
{
    return typeName(v.type);
}

/// Three-way comparison under the KBL total order.
int compareValues(in Value a, in Value b) @safe pure nothrow
{
    if (a.type != b.type)
        return a.type < b.type ? -1 : 1;
    final switch (a.type)
    {
    case ValueType.boolean:
    case ValueType.integer:
        return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
    case ValueType.str:
        return cmpBytes(a.s, b.s);
    case ValueType.list:
        immutable n = a.l.length < b.l.length ? a.l.length : b.l.length;
        foreach (k; 0 .. n)
        {
            immutable c = compareValues(a.l[k], b.l[k]);
            if (c != 0)
                return c;
        }
        return a.l.length < b.l.length ? -1 : (a.l.length > b.l.length ? 1 : 0);
    }
}

/// Deep structural equality.
bool valuesEqual(in Value a, in Value b) @safe pure nothrow
{
    if (a.type != b.type)
        return false;
    final switch (a.type)
    {
    case ValueType.boolean:
    case ValueType.integer:
        return a.i == b.i;
    case ValueType.str:
        return a.s == b.s;
    case ValueType.list:
        if (a.l.length != b.l.length)
            return false;
        foreach (k; 0 .. a.l.length)
            if (!valuesEqual(a.l[k], b.l[k]))
                return false;
        return true;
    }
}

/**
 * The text an interpolation (or `str()`) produces for a scalar value.
 * Must not be called with a list.
 */
string scalarText(in Value v) @safe pure nothrow
{
    final switch (v.type)
    {
    case ValueType.boolean:
        return v.i ? "true" : "false";
    case ValueType.integer:
        return decimal(v.i);
    case ValueType.str:
        return v.s;
    case ValueType.list:
        assert(0, "scalarText of a list");
    }
}

/// A canonical, injective byte encoding of a value, usable as a hash key.
void appendKey(ref char[] buf, in Value v) @safe pure nothrow
{
    final switch (v.type)
    {
    case ValueType.boolean:
        buf ~= v.i ? "b1" : "b0";
        break;
    case ValueType.integer:
        buf ~= 'i';
        buf ~= decimal(v.i);
        buf ~= ';';
        break;
    case ValueType.str:
        buf ~= 's';
        buf ~= decimal(cast(long) v.s.length);
        buf ~= ':';
        buf ~= v.s;
        break;
    case ValueType.list:
        buf ~= 'l';
        buf ~= decimal(cast(long) v.l.length);
        buf ~= ':';
        foreach (ref e; v.l)
            appendKey(buf, e);
        break;
    }
}

@safe pure unittest
{
    auto s = Value.ofStr("a"), t = Value.ofStr("b"), n = Value.ofInt(3), b = Value.ofBool(true);
    assert(compareValues(b, n) < 0 && compareValues(n, s) < 0 && compareValues(s, Value.ofList([])) < 0);
    assert(compareValues(s, t) < 0 && compareValues(Value.ofBool(false), b) < 0);
    auto l1 = Value.ofList([s, n]), l2 = Value.ofList([s, n, t]);
    assert(compareValues(l1, l2) < 0 && valuesEqual(l1, Value.ofList([s, n])));
    assert(!valuesEqual(Value.ofInt(1), Value.ofBool(true)));
    assert(scalarText(Value.ofInt(-7)) == "-7" && scalarText(b) == "true");
}

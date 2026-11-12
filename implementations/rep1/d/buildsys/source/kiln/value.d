/**
 * KBL values: `str`, `int`, `bool` and `list`, with their total order.
 */
module kiln.value;

import kiln.text : cmpBytes;

/// A KBL value.  Lists are immutable once built, so copying a `Value` is O(1).
struct Value
{
    /// The four value types, declared in the order of the cross-type ordering.
    enum Type : ubyte
    {
        boolean,
        integer,
        str,
        list,
    }

    /// Which member is meaningful.
    Type type;
    /// The payload of an `int` (or 0/1 for a `bool`).
    long num;
    /// The payload of a `str`.
    string text;
    /// The payload of a `list`.
    Value[] items;

    /// Makes a `bool`.
    static Value ofBool(bool b) @safe pure nothrow
    {
        Value v;
        v.type = Type.boolean;
        v.num = b;
        return v;
    }

    /// Makes an `int`.
    static Value ofInt(long n) @safe pure nothrow
    {
        Value v;
        v.type = Type.integer;
        v.num = n;
        return v;
    }

    /// Makes a `str`.
    static Value ofStr(string s) @safe pure nothrow
    {
        Value v;
        v.type = Type.str;
        v.text = s;
        return v;
    }

    /// Makes a `list`.
    static Value ofList(Value[] l) @safe pure nothrow
    {
        Value v;
        v.type = Type.list;
        v.items = l;
        return v;
    }

    /// The type token used in error messages.
    string typeName() const @safe pure nothrow @nogc
    {
        final switch (type)
        {
        case Type.boolean: return "bool";
        case Type.integer: return "int";
        case Type.str: return "str";
        case Type.list: return "list";
        }
    }

    /// The boolean payload.
    bool asBool() const @safe pure nothrow @nogc { return num != 0; }
}

/// Three-way comparison under the KBL total order.
int compareValues(const Value a, const Value b) @safe pure nothrow
{
    if (a.type != b.type)
        return a.type < b.type ? -1 : 1;
    final switch (a.type)
    {
    case Value.Type.boolean:
    case Value.Type.integer:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case Value.Type.str:
        return cmpBytes(a.text, b.text);
    case Value.Type.list:
        const n = a.items.length < b.items.length ? a.items.length : b.items.length;
        foreach (i; 0 .. n)
        {
            const c = compareValues(a.items[i], b.items[i]);
            if (c != 0)
                return c;
        }
        return a.items.length < b.items.length ? -1 : (a.items.length > b.items.length ? 1 : 0);
    }
}

/// Deep structural equality.
bool valuesEqual(const Value a, const Value b) @safe pure nothrow
{
    if (a.type != b.type)
        return false;
    final switch (a.type)
    {
    case Value.Type.boolean:
    case Value.Type.integer:
        return a.num == b.num;
    case Value.Type.str:
        return a.text == b.text;
    case Value.Type.list:
        if (a.items.length != b.items.length)
            return false;
        foreach (i; 0 .. a.items.length)
            if (!valuesEqual(a.items[i], b.items[i]))
                return false;
        return true;
    }
}

/// A string that is equal for two values iff the values are deeply equal.
string valueKey(const Value v) @safe pure nothrow
{
    import std.conv : to;

    final switch (v.type)
    {
    case Value.Type.boolean:
        return v.num ? "b1" : "b0";
    case Value.Type.integer:
        return "i" ~ v.num.to!string ~ ";";
    case Value.Type.str:
        return "s" ~ v.text.length.to!string ~ ":" ~ v.text;
    case Value.Type.list:
        string r = "l" ~ v.items.length.to!string ~ "[";
        foreach (ref e; v.items)
            r ~= valueKey(e);
        return r ~ "]";
    }
}

/// The text an interpolation (and `str()`) produces for a scalar; null for lists.
string scalarText(const Value v) @safe pure nothrow
{
    import std.conv : to;

    final switch (v.type)
    {
    case Value.Type.boolean: return v.num ? "true" : "false";
    case Value.Type.integer: return v.num.to!string;
    case Value.Type.str: return v.text;
    case Value.Type.list: return null;
    }
}

unittest
{
    alias V = Value;
    assert(compareValues(V.ofBool(true), V.ofInt(-5)) < 0);
    assert(compareValues(V.ofInt(99), V.ofStr("")) < 0);
    assert(compareValues(V.ofStr("zzz"), V.ofList([])) < 0);
    assert(compareValues(V.ofStr("a"), V.ofStr("ab")) < 0);
    assert(compareValues(V.ofList([V.ofInt(1), V.ofInt(2)]), V.ofList([V.ofInt(1)])) > 0);
    assert(compareValues(V.ofList([V.ofInt(1)]), V.ofList([V.ofInt(2)])) < 0);
    assert(valuesEqual(V.ofList([V.ofStr("a")]), V.ofList([V.ofStr("a")])));
    assert(!valuesEqual(V.ofInt(1), V.ofBool(true)));
    assert(valueKey(V.ofStr("a")) != valueKey(V.ofList([V.ofStr("a")])));
    assert(scalarText(V.ofInt(-3)) == "-3" && scalarText(V.ofBool(false)) == "false");
}

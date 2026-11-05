/**
 * KBL values: `bool`, `int`, `str` and `list`, with their total order,
 * structural equality and textual form.
 */
module kiln.value;

import kiln.errors;

import std.conv : to;

/// The four value types, declared in their total order.
enum VType : ubyte
{
    bool_,
    int_,
    str,
    list,
}

/// A KBL value. Copying is O(1): strings and lists are shared by handle.
struct Value
{
    VType type;
    /// Integer value, or 0/1 for `bool`.
    long i;
    /// Byte string for `str`.
    string s;
    /// Elements for `list`.
    Value[] l;

    ///
    static Value ofBool(bool b) @safe pure nothrow
    {
        Value v;
        v.type = VType.bool_;
        v.i = b;
        return v;
    }

    ///
    static Value ofInt(long n) @safe pure nothrow
    {
        Value v;
        v.type = VType.int_;
        v.i = n;
        return v;
    }

    ///
    static Value ofStr(string s) @safe pure nothrow
    {
        Value v;
        v.type = VType.str;
        v.s = s;
        return v;
    }

    ///
    static Value ofList(Value[] l) @safe pure nothrow
    {
        Value v;
        v.type = VType.list;
        v.l = l;
        return v;
    }

    /// The boolean payload of a `bool` value.
    bool b() const @safe pure nothrow @nogc
    {
        return i != 0;
    }
}

/// The name of a type as used in error messages.
string typeName(VType t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case VType.bool_:
        return "bool";
    case VType.int_:
        return "int";
    case VType.str:
        return "str";
    case VType.list:
        return "list";
    }
}

/// Total order of values: negative, zero or positive.
int compareValues(const ref Value a, const ref Value b) @safe pure
{
    if (a.type != b.type)
        return a.type < b.type ? -1 : 1;
    final switch (a.type)
    {
    case VType.bool_:
    case VType.int_:
        return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
    case VType.str:
        return a.s < b.s ? -1 : (a.s > b.s ? 1 : 0);
    case VType.list:
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
bool valuesEqual(const ref Value a, const ref Value b) @safe pure
{
    if (a.type != b.type)
        return false;
    final switch (a.type)
    {
    case VType.bool_:
    case VType.int_:
        return a.i == b.i;
    case VType.str:
        return a.s == b.s;
    case VType.list:
        if (a.l.length != b.l.length)
            return false;
        foreach (k; 0 .. a.l.length)
            if (!valuesEqual(a.l[k], b.l[k]))
                return false;
        return true;
    }
}

/// Text produced by interpolation or `str()`: strings as-is, decimal
/// integers, `true`/`false`. A list is `E_INTERP list`.
string interpolate(const ref Value v) @safe pure
{
    final switch (v.type)
    {
    case VType.bool_:
        return v.i ? "true" : "false";
    case VType.int_:
        return v.i.to!string;
    case VType.str:
        return v.s;
    case VType.list:
        throw new KilnError("E_INTERP", "list");
    }
}

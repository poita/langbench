/// KBL values: str, int, bool, list.
module kiln.value;

import kiln.bytes : Buf;
import kiln.errors;

/// Value types, declared in the order of the total order across types.
enum VKind : ubyte { boolean, integer, str, list }

/// A KBL value. Strings and lists are immutable and copy by handle.
struct Value
{
    VKind kind;
    long num;       /// integer value, or 0/1 for booleans
    string s;       /// str payload
    Value[] items;  /// list payload

    static Value ofStr(string s) @safe pure nothrow
    {
        Value v;
        v.kind = VKind.str;
        v.s = s;
        return v;
    }

    static Value ofInt(long n) @safe pure nothrow
    {
        Value v;
        v.kind = VKind.integer;
        v.num = n;
        return v;
    }

    static Value ofBool(bool b) @safe pure nothrow
    {
        Value v;
        v.kind = VKind.boolean;
        v.num = b;
        return v;
    }

    static Value ofList(Value[] items) @safe pure nothrow
    {
        Value v;
        v.kind = VKind.list;
        v.items = items;
        return v;
    }

    bool isStr() const @safe pure nothrow @nogc { return kind == VKind.str; }
    bool isInt() const @safe pure nothrow @nogc { return kind == VKind.integer; }
    bool isBool() const @safe pure nothrow @nogc { return kind == VKind.boolean; }
    bool isList() const @safe pure nothrow @nogc { return kind == VKind.list; }
}

/// The KBL name of a value type: `bool`, `int`, `str` or `list`.
string typeName(VKind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
    case VKind.boolean: return "bool";
    case VKind.integer: return "int";
    case VKind.str: return "str";
    case VKind.list: return "list";
    }
}

/// Total order over values: -1, 0 or 1.
int compareValues(const ref Value a, const ref Value b) @safe pure nothrow
{
    if (a.kind != b.kind)
        return a.kind < b.kind ? -1 : 1;
    final switch (a.kind)
    {
    case VKind.boolean:
    case VKind.integer:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case VKind.str:
        return a.s < b.s ? -1 : (a.s > b.s ? 1 : 0);
    case VKind.list:
        immutable n = a.items.length < b.items.length ? a.items.length : b.items.length;
        foreach (i; 0 .. n)
        {
            immutable c = compareValues(a.items[i], b.items[i]);
            if (c != 0)
                return c;
        }
        return a.items.length < b.items.length ? -1 : (a.items.length > b.items.length ? 1 : 0);
    }
}

/// Deep structural equality.
bool valuesEqual(const ref Value a, const ref Value b) @safe pure nothrow
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case VKind.boolean:
    case VKind.integer:
        return a.num == b.num;
    case VKind.str:
        return a.s == b.s;
    case VKind.list:
        if (a.items.length != b.items.length)
            return false;
        foreach (i; 0 .. a.items.length)
            if (!valuesEqual(a.items[i], b.items[i]))
                return false;
        return true;
    }
}

/// Append the interpolation text of a scalar to `b`; a list is `E_INTERP list`.
void putInterpolated(ref Buf b, const ref Value v) @safe pure
{
    final switch (v.kind)
    {
    case VKind.str: b.put(v.s); break;
    case VKind.integer: b.putInt(v.num); break;
    case VKind.boolean: b.put(v.num ? "true" : "false"); break;
    case VKind.list: throw new KilnError("E_INTERP", "list");
    }
}

/// Text of a scalar value as interpolation produces it.
string interpolatedText(const ref Value v) @safe pure
{
    if (v.kind == VKind.str)
        return v.s;
    Buf b;
    putInterpolated(b, v);
    return b.take();
}

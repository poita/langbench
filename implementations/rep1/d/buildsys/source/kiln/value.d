/// The four KBL value types, their total order and structural equality.
module kiln.value;

/// A KBL value: `bool`, `int`, `str` or `list`.
///
/// Strings are immutable byte strings and lists are immutable arrays of values,
/// so copying a `Value` is O(1).
struct Value
{
    /// Discriminator; the declaration order is the cross-type sort order.
    enum Type : ubyte
    {
        boolean,
        integer,
        str,
        list
    }

    Type type;
    long num; /// payload of `boolean` (0/1) and `integer`
    string s; /// payload of `str`
    Value[] items; /// payload of `list`

    /// A `bool` value.
    static Value ofBool(bool b) @safe
    {
        Value v;
        v.type = Type.boolean;
        v.num = b ? 1 : 0;
        return v;
    }

    /// An `int` value.
    static Value ofInt(long n) @safe
    {
        Value v;
        v.type = Type.integer;
        v.num = n;
        return v;
    }

    /// A `str` value.
    static Value ofStr(string s) @safe
    {
        Value v;
        v.type = Type.str;
        v.s = s;
        return v;
    }

    /// A `list` value.
    static Value ofList(Value[] items) @safe
    {
        Value v;
        v.type = Type.list;
        v.items = items;
        return v;
    }

    /// True for a `bool` that is true.
    bool isTrue() const @safe
    {
        return type == Type.boolean && num != 0;
    }

    /// The KBL type token: `str`, `int`, `bool` or `list`.
    string typeName() const @safe
    {
        return typeNameOf(type);
    }
}

/// The KBL type token of a type.
string typeNameOf(Value.Type t) @safe
{
    final switch (t)
    {
    case Value.Type.boolean:
        return "bool";
    case Value.Type.integer:
        return "int";
    case Value.Type.str:
        return "str";
    case Value.Type.list:
        return "list";
    }
}

/// Three-way comparison in the KBL total order (negative, zero, positive).
int compareValues(const ref Value a, const ref Value b) @safe
{
    if (a.type != b.type)
        return a.type < b.type ? -1 : 1;
    final switch (a.type)
    {
    case Value.Type.boolean:
    case Value.Type.integer:
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    case Value.Type.str:
        return a.s < b.s ? -1 : (a.s == b.s ? 0 : 1);
    case Value.Type.list:
        const n = a.items.length < b.items.length ? a.items.length : b.items.length;
        foreach (i; 0 .. n)
        {
            const c = compareValues(a.items[i], b.items[i]);
            if (c != 0)
                return c;
        }
        return a.items.length < b.items.length ? -1 : (a.items.length == b.items.length ? 0 : 1);
    }
}

/// Deep structural equality; values of different types are never equal.
bool valuesEqual(const ref Value a, const ref Value b) @safe
{
    if (a.type != b.type)
        return false;
    final switch (a.type)
    {
    case Value.Type.boolean:
    case Value.Type.integer:
        return a.num == b.num;
    case Value.Type.str:
        return a.s == b.s;
    case Value.Type.list:
        if (a.items.length != b.items.length)
            return false;
        foreach (i; 0 .. a.items.length)
            if (!valuesEqual(a.items[i], b.items[i]))
                return false;
        return true;
    }
}

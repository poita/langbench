/// Runtime values of the template language.
module sitegen.templating.value;

import std.array : Appender, appender;
import std.format : format;

/// The kind of a `Value`.
enum Kind : ubyte
{
    undefined,
    none,
    boolean,
    integer,
    floating,
    text,
    list,
    dict,
    macroDef,
    rangeFn,
    superFn,
    loop,
}

/// A list payload (shared by reference; never mutated after construction).
final class ListObj
{
    Value[] items;
    this(Value[] items) pure nothrow @safe
    {
        this.items = items;
    }
}

/// An insertion-ordered string-keyed dictionary.
final class DictObj
{
    string[] keys;
    Value[] values;
    private size_t[string] index;
    private bool indexed;

    /// Number of members.
    size_t length() const pure nothrow @safe @nogc
    {
        return keys.length;
    }

    /// Add or replace member `key`.
    void set(string key, Value v) pure nothrow @safe
    {
        size_t at;
        if (find(key, at))
        {
            values[at] = v;
            return;
        }
        if (indexed)
            index[key] = keys.length;
        keys ~= key;
        values ~= v;
    }

    private bool find(string key, out size_t at) pure nothrow @safe
    {
        if (keys.length > 10)
        {
            if (!indexed)
            {
                foreach (i, k; keys)
                    index[k] = i;
                indexed = true;
            }
            if (auto p = key in index)
            {
                at = *p;
                return true;
            }
            return false;
        }
        foreach (i, k; keys)
            if (k == key)
            {
                at = i;
                return true;
            }
        return false;
    }

    /// Look up `key`; false if there is no such member.
    bool tryGet(string key, out Value v) pure nothrow @safe
    {
        size_t at;
        if (!find(key, at))
            return false;
        v = values[at];
        return true;
    }
}

/// A defined macro: its statement, the scope it was defined in and the
/// rendering it belongs to.
final class MacroObj
{
    import sitegen.templating.ast : Stmt;
    import sitegen.templating.scopes : Scope;

    Stmt node;
    Scope definedIn;
    Object rendering;

    this(Stmt node, Scope definedIn, Object rendering) pure nothrow @safe
    {
        this.node = node;
        this.definedIn = definedIn;
        this.rendering = rendering;
    }
}

/// A `super` binding: block name and chain index.
final class SuperObj
{
    Object rendering;
    string name;
    size_t index;

    this(Object rendering, string name, size_t index) pure nothrow @safe
    {
        this.rendering = rendering;
        this.name = name;
        this.index = index;
    }
}

/// A template value. Strings, lists and dicts are shared by reference, so
/// copying a `Value` is cheap.
struct Value
{
    Kind kind;
    long i; /// integer, boolean (0/1), or the 0-based index of a loop
    double d; /// float
    string s; /// text
    Object o; /// list, dict, macro or super payload
    long aux; /// loop length

    static Value undefined() pure nothrow @safe @nogc
    {
        return Value.init;
    }

    static Value none() pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.none;
        return v;
    }

    static Value of(bool b) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.boolean;
        v.i = b;
        return v;
    }

    static Value of(long n) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.integer;
        v.i = n;
        return v;
    }

    static Value of(int n) pure nothrow @safe @nogc
    {
        return of(cast(long) n);
    }

    static Value of(double x) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.floating;
        v.d = x;
        return v;
    }

    static Value of(string str) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.text;
        v.s = str;
        return v;
    }

    static Value of(Value[] items) pure nothrow @safe
    {
        Value v;
        v.kind = Kind.list;
        v.o = new ListObj(items);
        return v;
    }

    static Value of(DictObj dict) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.dict;
        v.o = dict;
        return v;
    }

    /// Make a list of strings.
    static Value ofStrings(const(string)[] items) pure nothrow @safe
    {
        auto vs = new Value[items.length];
        foreach (k, it; items)
            vs[k] = Value.of(it);
        return Value.of(vs);
    }

    bool isUndefined() const pure nothrow @safe @nogc
    {
        return kind == Kind.undefined;
    }

    /// True for integers, floats and booleans.
    bool isNumber() const pure nothrow @safe @nogc
    {
        return kind == Kind.integer || kind == Kind.floating || kind == Kind.boolean;
    }

    /// The payload of a list value.
    Value[] items() pure nothrow @trusted @nogc
    {
        return (cast(ListObj) cast(void*) o).items;
    }

    /// The payload of a dict value.
    DictObj dict() pure nothrow @trusted @nogc
    {
        return cast(DictObj) cast(void*) o;
    }

    double asDouble() const pure nothrow @safe @nogc
    {
        return kind == Kind.floating ? d : cast(double) i;
    }
}

// ----------------------------------------------------------------------
// printing

/// Parse a decimal floating-point literal with correct rounding.
///
/// (`std.conv.to!double` is not correctly rounded for every input, and the
/// shortest-representation search in `formatFloat` depends on exactness.)
double parseDouble(string text) nothrow
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    return strtod(toStringz(text), null);
}

/// Format a double the way Python's `repr` does.
string formatFloat(double v)
{
    import std.conv : to;
    import std.math : isNaN, isInfinity, signbit;

    if (v != v)
        return "nan";
    if (v == double.infinity)
        return "inf";
    if (v == -double.infinity)
        return "-inf";
    if (v == 0)
        return signbit(v) ? "-0.0" : "0.0";

    string sci;
    foreach (prec; 15 .. 18)
    {
        sci = format("%.*e", prec - 1, v);
        if (parseDouble(sci) == v)
            break;
    }
    bool neg = sci[0] == '-';
    if (neg)
        sci = sci[1 .. $];
    size_t epos = 0;
    while (sci[epos] != 'e')
        ++epos;
    int exp10 = sci[epos + 1 .. $].to!int;
    char[] digits;
    foreach (c; sci[0 .. epos])
        if (c != '.')
            digits ~= c;
    while (digits.length > 1 && digits[$ - 1] == '0')
        digits.length = digits.length - 1;

    auto o = appender!(char[])();
    if (neg)
        o.put('-');
    if (exp10 >= -4 && exp10 < 16)
    {
        if (exp10 >= 0)
        {
            foreach (k; 0 .. exp10 + 1)
                o.put(k < digits.length ? digits[k] : '0');
            o.put('.');
            if (digits.length > exp10 + 1)
                o.put(digits[exp10 + 1 .. $]);
            else
                o.put('0');
        }
        else
        {
            o.put("0.");
            foreach (_; 0 .. -exp10 - 1)
                o.put('0');
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
        o.put(exp10 < 0 ? '-' : '+');
        immutable ae = exp10 < 0 ? -exp10 : exp10;
        if (ae < 10)
            o.put('0');
        o.put(format("%d", ae));
    }
    return o.data.idup;
}

private void putRepr(ref Appender!(char[]) o, Value v)
{
    if (v.kind != Kind.text)
    {
        putDisplay(o, v);
        return;
    }
    bool hasSingle, hasDouble;
    foreach (c; v.s)
    {
        if (c == '\'')
            hasSingle = true;
        else if (c == '"')
            hasDouble = true;
    }
    immutable quote = hasSingle && !hasDouble ? '"' : '\'';
    o.put(quote);
    foreach (c; v.s)
    {
        switch (c)
        {
        case '\\': o.put("\\\\"); break;
        case '\n': o.put("\\n"); break;
        case '\r': o.put("\\r"); break;
        case '\t': o.put("\\t"); break;
        default:
            if (c == quote)
            {
                o.put('\\');
                o.put(c);
            }
            else
                o.put(c);
        }
    }
    o.put(quote);
}

/// Append the printed form of `v` (as `{{ v }}` would print it). The caller
/// must have rejected the undefined value.
void putDisplay(ref Appender!(char[]) o, Value v)
{
    final switch (v.kind)
    {
    case Kind.undefined:
        break;
    case Kind.none:
        o.put("None");
        break;
    case Kind.boolean:
        o.put(v.i ? "True" : "False");
        break;
    case Kind.integer:
        o.put(format("%d", v.i));
        break;
    case Kind.floating:
        o.put(formatFloat(v.d));
        break;
    case Kind.text:
        o.put(v.s);
        break;
    case Kind.list:
        o.put('[');
        foreach (k, it; v.items)
        {
            if (k)
                o.put(", ");
            putRepr(o, it);
        }
        o.put(']');
        break;
    case Kind.dict:
        o.put('{');
        auto dobj = v.dict;
        foreach (k, key; dobj.keys)
        {
            if (k)
                o.put(", ");
            putRepr(o, Value.of(key));
            o.put(": ");
            putRepr(o, dobj.values[k]);
        }
        o.put('}');
        break;
    case Kind.macroDef:
    case Kind.rangeFn:
    case Kind.superFn:
    case Kind.loop:
        o.put("<callable>");
        break;
    }
}

/// The printed form of `v` as a string.
string toDisplay(Value v)
{
    if (v.kind == Kind.text)
        return v.s;
    auto o = appender!(char[])();
    putDisplay(o, v);
    return o.data.idup;
}

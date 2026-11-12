/// The dynamic value type of the template language.
module jinjalite.value;

import std.array : Appender, appender;
import jinjalite.errors;
import jinjalite.floatfmt;

/// The kinds of value a template expression can produce.
enum Kind : ubyte
{
    /// A name or member that does not exist; almost every use of it is an error.
    undefined,
    /// JSON `null`.
    none,
    /// `true` / `false`; behaves as the integers 1 / 0 except when printed.
    boolean,
    /// 64-bit signed integer.
    integer,
    /// IEEE double.
    floating,
    /// UTF-8 text (a sequence of Unicode code points).
    text,
    /// Shared immutable-by-convention list.
    list,
    /// Insertion-ordered dictionary with string keys.
    dict,
    /// A macro closure (interpreter-defined payload).
    macroFn,
    /// The built-in `range` function.
    builtin,
    /// The `super` function bound inside a block body (interpreter-defined payload).
    superFn,
    /// The `loop` object bound inside a `for` body.
    loop,
}

/// Heap storage of a list value; shared by every `Value` that refers to it.
final class List
{
    /// The elements.
    Value[] items;

    ///
    this(Value[] items) pure nothrow @safe
    {
        this.items = items;
    }
}

/// Insertion-ordered dictionary with expected O(1) lookup.
final class Dict
{
    /// Keys in insertion order.
    string[] keys;
    /// Values, parallel to `keys`.
    Value[] values;
    private size_t[string] index;

    /// Number of members.
    size_t length() const pure nothrow @safe @nogc
    {
        return keys.length;
    }

    /// A pointer to the value stored under `key`, or `null`. Invalidated by `set`.
    Value* find(string key)
    {
        if (auto p = key in index)
            return &values[*p];
        return null;
    }

    /// Insert `key`, or overwrite its value keeping its original position.
    void set(string key, Value value)
    {
        if (auto p = key in index)
        {
            values[*p] = value;
            return;
        }
        index[key] = keys.length;
        keys ~= key;
        values ~= value;
    }
}

/// State of the innermost enclosing `for` loop (the `loop` variable).
final class LoopInfo
{
    /// Zero-based position of the current iteration.
    long index0;
    /// Number of iterations.
    long length;

    ///
    this(long index0, long length) pure nothrow @safe @nogc
    {
        this.index0 = index0;
        this.length = length;
    }
}

/++
    A template value. Copying a `Value` is O(1): strings, lists and dicts are
    shared, never duplicated.
+/
struct Value
{
    /// Which kind of value this is.
    Kind kind = Kind.undefined;
    union
    {
        /// Payload of `integer` and `boolean` values.
        long i;
        /// Payload of `floating` values.
        double d;
    }
    /// Payload of `text` values.
    string s;
    /// Payload of `list`, `dict`, `macro`, `superFn` and `loop` values.
    Object obj;

    /// The undefined value.
    static Value undefined() pure nothrow @safe @nogc
    {
        return Value.init;
    }

    /// The none value.
    static Value none() pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.none;
        return v;
    }

    /// A boolean.
    static Value boolean(bool b) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.boolean;
        v.i = b;
        return v;
    }

    /// An integer.
    static Value integer(long n) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.integer;
        v.i = n;
        return v;
    }

    /// A float.
    static Value floating(double x) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.floating;
        v.d = x;
        return v;
    }

    /// A string (not copied).
    static Value text(string s) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.text;
        v.s = s;
        return v;
    }

    /// A list that takes ownership of `items`.
    static Value list(Value[] items) pure nothrow @safe
    {
        Value v;
        v.kind = Kind.list;
        v.obj = new List(items);
        return v;
    }

    /// A dict value wrapping `d`.
    static Value dict(Dict d) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.dict;
        v.obj = d;
        return v;
    }

    /// A value of one of the object-carrying kinds (`macro`, `superFn`, `loop`).
    static Value object(Kind kind, Object payload) pure nothrow @safe @nogc
    {
        Value v;
        v.kind = kind;
        v.obj = payload;
        return v;
    }

    /// A value of kind `builtin`.
    static Value builtin() pure nothrow @safe @nogc
    {
        Value v;
        v.kind = Kind.builtin;
        return v;
    }

    /// True for the undefined value.
    bool isUndefined() const pure nothrow @safe @nogc
    {
        return kind == Kind.undefined;
    }

    /// True for integer, float and boolean values.
    bool isNumber() const pure nothrow @safe @nogc
    {
        return kind == Kind.integer || kind == Kind.floating || kind == Kind.boolean;
    }

    /// True for integer and boolean values (anything usable as an integer).
    bool isIntegral() const pure nothrow @safe @nogc
    {
        return kind == Kind.integer || kind == Kind.boolean;
    }

    /// The numeric value as a double. Only valid when `isNumber`.
    double asDouble() const pure nothrow @safe @nogc
    {
        return kind == Kind.floating ? d : cast(double) i;
    }

    /// The elements of a list value.
    Value[] items() pure nothrow @trusted
    {
        return (cast(List) obj).items;
    }

    /// The dictionary of a dict value.
    Dict asDict() pure nothrow @trusted
    {
        return cast(Dict) obj;
    }
}

/// Throw an `undefined` error when `v` is the undefined value.
void requireDefined(Value v, string what = "use of an undefined value") pure @safe
{
    if (v.kind == Kind.undefined)
        undefinedError(what);
}

/// Truthiness: false, none, 0, 0.0, "", [] and {} are falsy. Undefined is an error.
bool truthy(Value v) pure
{
    final switch (v.kind)
    {
    case Kind.undefined:
        undefinedError("the truth value of an undefined value was requested");
    case Kind.none:
        return false;
    case Kind.boolean:
    case Kind.integer:
        return v.i != 0;
    case Kind.floating:
        return v.d != 0.0;
    case Kind.text:
        return v.s.length != 0;
    case Kind.list:
        return v.items.length != 0;
    case Kind.dict:
        return v.asDict.length != 0;
    case Kind.macroFn:
    case Kind.builtin:
    case Kind.superFn:
    case Kind.loop:
        return true;
    }
}

/// Number of Unicode code points in a UTF-8 string.
size_t codePointCount(string s) pure nothrow @safe @nogc
{
    size_t n = 0;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}

/// Length in bytes of the UTF-8 sequence starting with lead byte `c`.
size_t utf8Length(char c) pure nothrow @safe @nogc
{
    if (c < 0x80) return 1;
    if (c < 0xE0) return 2;
    if (c < 0xF0) return 3;
    return 4;
}

/// Append the number `n` in decimal.
void putInteger(Sink)(ref Sink sink, long n)
{
    char[20] buf = void;
    size_t p = buf.length;
    ulong u = n < 0 ? -cast(ulong) n : cast(ulong) n;
    do
    {
        buf[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u != 0);
    if (n < 0)
        buf[--p] = '-';
    sink.put(buf[p .. $]);
}

/// Append the quoted, escaped form of a string (Python-style `repr`).
void putQuoted(Sink)(ref Sink sink, string s)
{
    bool hasSingle = false, hasDouble = false;
    foreach (c; s)
    {
        if (c == '\'') hasSingle = true;
        else if (c == '"') hasDouble = true;
    }
    const char quote = (hasSingle && !hasDouble) ? '"' : '\'';
    sink.put(quote);
    size_t start = 0;
    foreach (idx, c; s)
    {
        string esc;
        switch (c)
        {
        case '\\': esc = "\\\\"; break;
        case '\n': esc = "\\n"; break;
        case '\r': esc = "\\r"; break;
        case '\t': esc = "\\t"; break;
        case '\'': if (quote == '\'') esc = "\\'"; break;
        default: break;
        }
        if (esc.length)
        {
            sink.put(s[start .. idx]);
            sink.put(esc);
            start = idx + 1;
        }
    }
    sink.put(s[start .. $]);
    sink.put(quote);
}

/++
    Append the printed form of `v` to `sink`. With `repr` set, strings are
    quoted (as inside printed lists and dicts).
+/
void putValue(Sink)(ref Sink sink, Value v, bool repr = false)
{
    final switch (v.kind)
    {
    case Kind.undefined:
        undefinedError("printing an undefined value");
    case Kind.none:
        sink.put("None");
        break;
    case Kind.boolean:
        sink.put(v.i ? "True" : "False");
        break;
    case Kind.integer:
        putInteger(sink, v.i);
        break;
    case Kind.floating:
        sink.put(formatFloat(v.d));
        break;
    case Kind.text:
        if (repr)
            putQuoted(sink, v.s);
        else
            sink.put(v.s);
        break;
    case Kind.list:
        sink.put('[');
        foreach (idx, item; v.items)
        {
            if (idx)
                sink.put(", ");
            putValue(sink, item, true);
        }
        sink.put(']');
        break;
    case Kind.dict:
        sink.put('{');
        auto d = v.asDict;
        foreach (idx, key; d.keys)
        {
            if (idx)
                sink.put(", ");
            putQuoted(sink, key);
            sink.put(": ");
            putValue(sink, d.values[idx], true);
        }
        sink.put('}');
        break;
    case Kind.macroFn:
        sink.put("<macro>");
        break;
    case Kind.builtin:
        sink.put("<built-in range>");
        break;
    case Kind.superFn:
        sink.put("<super>");
        break;
    case Kind.loop:
        sink.put("<loop>");
        break;
    }
}

/// The string form of `v` as used by printing, `~` and the string filters.
string toStr(Value v)
{
    if (v.kind == Kind.text)
        return v.s;
    auto sink = appender!string();
    putValue(sink, v);
    return sink.data;
}

/// Equality as defined by `==`: never an error for defined values.
bool valuesEqual(Value a, Value b)
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
    case Kind.none:
        return true;
    case Kind.text:
        return a.s == b.s;
    case Kind.list:
    {
        if (a.obj is b.obj)
            return true;
        auto x = a.items, y = b.items;
        if (x.length != y.length)
            return false;
        foreach (idx; 0 .. x.length)
            if (!valuesEqual(x[idx], y[idx]))
                return false;
        return true;
    }
    case Kind.dict:
    {
        auto x = a.asDict, y = b.asDict;
        if (x is y)
            return true;
        if (x.length != y.length)
            return false;
        foreach (idx, key; x.keys)
        {
            auto other = y.find(key);
            if (other is null || !valuesEqual(x.values[idx], *other))
                return false;
        }
        return true;
    }
    case Kind.macroFn:
    case Kind.superFn:
    case Kind.loop:
        return a.obj is b.obj;
    case Kind.builtin:
        return true;
    default:
        return false;
    }
}

/// Three-way comparison of two strings by code point (equivalently, by UTF-8 bytes).
int compareText(string a, string b) pure nothrow @trusted @nogc
{
    import core.stdc.string : memcmp;
    const n = a.length < b.length ? a.length : b.length;
    const c = n ? memcmp(a.ptr, b.ptr, n) : 0;
    if (c != 0)
        return c < 0 ? -1 : 1;
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

unittest
{
    assert(toStr(Value.integer(-42)) == "-42");
    assert(toStr(Value.integer(long.min)) == "-9223372036854775808");
    assert(toStr(Value.boolean(true)) == "True");
    assert(toStr(Value.none) == "None");
    assert(toStr(Value.floating(2.0)) == "2.0");
    auto d = new Dict;
    d.set("k", Value.list([Value.floating(2.0)]));
    auto l = Value.list([Value.integer(1), Value.text("a"), Value.boolean(true), Value.none,
        Value.floating(1.5), Value.text("it's"), Value.dict(d)]);
    assert(toStr(l) == `[1, 'a', True, None, 1.5, "it's", {'k': [2.0]}]`);
    assert(toStr(Value.list([Value.text("a\n'\"\\")])) == `['a\n\'"\\']`);
    assert(toStr(Value.list([])) == "[]");
    assert(toStr(Value.dict(new Dict)) == "{}");
}

unittest
{
    assert(!truthy(Value.text("")));
    assert(truthy(Value.text("0")));
    assert(!truthy(Value.floating(0.0)));
    assert(!truthy(Value.list([])));
    assert(truthy(Value.list([Value.none])));
    assert(valuesEqual(Value.boolean(true), Value.integer(1)));
    assert(valuesEqual(Value.integer(1), Value.floating(1.0)));
    assert(!valuesEqual(Value.integer(1), Value.text("1")));
    assert(!valuesEqual(Value.none, Value.integer(0)));
    assert(valuesEqual(Value.list([Value.integer(1)]), Value.list([Value.floating(1.0)])));
    assert(compareText("ab", "abc") < 0);
    assert(compareText("b", "abc") > 0);
    assert(codePointCount("héllo") == 5);
}

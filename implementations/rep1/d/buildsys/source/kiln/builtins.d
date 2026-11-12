/**
 * The 39 built-in functions of KBL.
 */
module kiln.builtins;

import kiln.errors;
import kiln.glob;
import kiln.text;
import kiln.value;
import kiln.vfs;

/// Parameter type constraints.
enum ArgType : ubyte { any, str, int_, bool_, list, strOrList, strOrInt, strIntBool }

/// A built-in function descriptor.
struct Builtin
{
    ///
    string name;
    ///
    ArgType[] params;
    ///
    size_t minArgs, maxArgs;
    ///
    Value function(Value[] args, Vfs fs) run;
}

private __gshared Builtin[string] table;

/// Looks up a built-in by name; null if there is none.
const(Builtin)* findBuiltin(const(char)[] name)
{
    auto p = name in table;
    return p ? p : null;
}

/// Names of all built-in functions.
string[] builtinNames()
{
    return table.keys;
}

private string expectedName(ArgType t) @safe pure nothrow
{
    final switch (t)
    {
    case ArgType.any: return "any";
    case ArgType.str: return "str";
    case ArgType.int_: return "int";
    case ArgType.bool_: return "bool";
    case ArgType.list: return "list";
    case ArgType.strOrList: return "str|list";
    case ArgType.strOrInt: return "str|int";
    case ArgType.strIntBool: return "str|int|bool";
    }
}

private bool accepts(ArgType t, Value.Type v) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ArgType.any: return true;
    case ArgType.str: return v == Value.Type.str;
    case ArgType.int_: return v == Value.Type.integer;
    case ArgType.bool_: return v == Value.Type.boolean;
    case ArgType.list: return v == Value.Type.list;
    case ArgType.strOrList: return v == Value.Type.str || v == Value.Type.list;
    case ArgType.strOrInt: return v == Value.Type.str || v == Value.Type.integer;
    case ArgType.strIntBool: return v != Value.Type.list;
    }
}

/**
 * Checks the arity and the argument types of a call (steps 3 and 4 of a call).
 *
 * Throws: `KilnError` (`E_ARITY` or `E_TYPE`).
 */
void checkCall(const(Builtin)* b, const(Value)[] args)
{
    import std.conv : to;

    if (args.length < b.minArgs || args.length > b.maxArgs)
    {
        const expected = b.minArgs == b.maxArgs ? b.minArgs.to!string : b.minArgs.to!string ~ "-" ~ b.maxArgs.to!string;
        throw new KilnError("E_ARITY", "fn " ~ b.name ~ ": expected " ~ expected ~ ", got " ~ args.length.to!string);
    }
    foreach (i, ref a; args)
        if (!accepts(b.params[i], a.type))
            throw typeError("fn " ~ b.name ~ " argument " ~ (i + 1).to!string, expectedName(b.params[i]), a.typeName);
}

private KilnError argError(string fn, string reason) @safe pure nothrow
{
    return new KilnError("E_ARG", "fn " ~ fn ~ ": " ~ reason);
}

private void clampRange(size_t n, long start, long count, out size_t s, out size_t c) @safe pure nothrow @nogc
{
    long st = start;
    if (st < 0)
        st = cast(long) n + st;
    if (st < 0)
        st = 0;
    if (st > cast(long) n)
        st = cast(long) n;
    long cn = count;
    const room = cast(long) n - st;
    if (cn < 0)
        cn = 0;
    if (cn > room)
        cn = room;
    s = cast(size_t) st;
    c = cast(size_t) cn;
}

private string[] stringElements(string fn, const(Value)[] items)
{
    import std.conv : to;

    string[] r;
    foreach (i, ref e; items)
    {
        if (e.type != Value.Type.str)
            throw typeError("fn " ~ fn ~ " element " ~ i.to!string, "str", e.typeName);
        r ~= e.text;
    }
    return r;
}

private Value filterImpl(string fn, Value[] a, bool keep)
{
    import std.conv : to;

    GlobPattern pat;
    if (!GlobPattern.compile(a[1].text, pat))
        throw argError(fn, "bad pattern");
    Value[] r;
    foreach (i, ref e; a[0].items)
    {
        if (e.type != Value.Type.str)
            throw typeError("fn " ~ fn ~ " element " ~ i.to!string, "str", e.typeName);
        if (pat.matches(e.text) == keep)
            r ~= e;
    }
    return Value.ofList(r);
}

private string baseName(string p) @safe pure nothrow
{
    foreach_reverse (i, char c; p)
        if (c == '/')
            return p[i + 1 .. $];
    return p;
}

/// Splits a basename at its last dot that is not at index 0; returns the dot index or -1.
private ptrdiff_t extDot(string b) @safe pure nothrow @nogc
{
    foreach_reverse (i, char c; b)
        if (c == '.' && i != 0)
            return cast(ptrdiff_t) i;
    return -1;
}

private Value parseIntValue(string s)
{
    size_t i = 0;
    bool neg = false;
    if (s.length && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i >= s.length)
        throw argError("int", "bad integer");
    const ulong limit = neg ? (1UL << 63) : (1UL << 63) - 1;
    ulong mag = 0;
    foreach (char c; s[i .. $])
    {
        if (c < '0' || c > '9')
            throw argError("int", "bad integer");
        const d = c - '0';
        if (mag > (limit - d) / 10)
            throw argError("int", "bad integer");
        mag = mag * 10 + d;
    }
    return Value.ofInt(neg ? cast(long)(0 - mag) : cast(long) mag);
}

private void reg(string name, ArgType[] params, Value function(Value[], Vfs) fn)
{
    table[name] = Builtin(name, params, params.length, params.length, fn);
}

shared static this()
{
    import std.algorithm.sorting : sort;
    import std.conv : to;

    alias T = ArgType;
    alias V = Value;

    reg("len", [T.strOrList], (a, fs) => V.ofInt(a[0].type == V.Type.str ? a[0].text.length : a[0].items.length));
    reg("count", [T.list], (a, fs) => V.ofInt(a[0].items.length));
    reg("upper", [T.str], (a, fs) {
        char[] r = a[0].text.dup;
        foreach (ref c; r)
            if (c >= 'a' && c <= 'z')
                c -= 32;
        return V.ofStr(r.idup);
    });
    reg("lower", [T.str], (a, fs) {
        char[] r = a[0].text.dup;
        foreach (ref c; r)
            if (c >= 'A' && c <= 'Z')
                c += 32;
        return V.ofStr(r.idup);
    });
    reg("trim", [T.str], (a, fs) {
        static bool ws(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
        string s = a[0].text;
        size_t lo = 0, hi = s.length;
        while (lo < hi && ws(s[lo]))
            ++lo;
        while (hi > lo && ws(s[hi - 1]))
            --hi;
        return V.ofStr(s[lo .. hi]);
    });
    reg("replace", [T.str, T.str, T.str], (a, fs) {
        if (a[1].text.length == 0)
            throw argError("replace", "empty pattern");
        return V.ofStr(replaceAllBytes(a[0].text, a[1].text, a[2].text));
    });
    reg("starts_with", [T.str, T.str], (a, fs) => V.ofBool(startsWithBytes(a[0].text, a[1].text)));
    reg("ends_with", [T.str, T.str], (a, fs) => V.ofBool(endsWithBytes(a[0].text, a[1].text)));
    reg("contains", [T.str, T.str], (a, fs) => V.ofBool(containsBytes(a[0].text, a[1].text)));
    reg("substr", [T.str, T.int_, T.int_], (a, fs) {
        size_t s, c;
        clampRange(a[0].text.length, a[1].num, a[2].num, s, c);
        return V.ofStr(a[0].text[s .. s + c]);
    });
    reg("split", [T.str, T.str], (a, fs) {
        const sep = a[1].text;
        if (sep.length == 0)
            throw argError("split", "empty separator");
        const s = a[0].text;
        Value[] r;
        size_t i = 0;
        while (true)
        {
            const j = findBytes(s, sep, i);
            if (j < 0)
            {
                r ~= V.ofStr(s[i .. $]);
                break;
            }
            r ~= V.ofStr(s[i .. j]);
            i = j + sep.length;
        }
        return V.ofList(r);
    });
    reg("join", [T.list, T.str], (a, fs) {
        char[] r;
        foreach (i, ref e; a[0].items)
        {
            if (e.type != V.Type.str && e.type != V.Type.integer)
                throw typeError("fn join element " ~ i.to!string, "str|int", e.typeName);
            if (i > 0)
                r ~= a[1].text;
            r ~= scalarText(e);
        }
        return V.ofStr(r.idup);
    });
    reg("str", [T.strIntBool], (a, fs) => V.ofStr(scalarText(a[0])));
    reg("int", [T.strOrInt], (a, fs) => a[0].type == V.Type.integer ? a[0] : parseIntValue(a[0].text));
    reg("dirname", [T.str], (a, fs) {
        const s = a[0].text;
        foreach_reverse (i, char c; s)
            if (c == '/')
                return V.ofStr(s[0 .. i]);
        return V.ofStr("");
    });
    reg("basename", [T.str], (a, fs) => V.ofStr(baseName(a[0].text)));
    reg("stem", [T.str], (a, fs) {
        const b = baseName(a[0].text);
        const d = extDot(b);
        return V.ofStr(d < 0 ? b : b[0 .. d]);
    });
    reg("ext", [T.str], (a, fs) {
        const b = baseName(a[0].text);
        const d = extDot(b);
        return V.ofStr(d < 0 ? "" : b[d .. $]);
    });
    table["pathjoin"] = Builtin("pathjoin", [T.str, T.str, T.str, T.str, T.str, T.str, T.str, T.str], 1, 8, (a, fs) {
        string r;
        bool first = true;
        foreach (ref e; a)
        {
            if (e.text.length == 0)
                continue;
            if (!first)
                r ~= "/";
            r ~= e.text;
            first = false;
        }
        return V.ofStr(r);
    });
    reg("map", [T.list, T.str], (a, fs) {
        const strs = stringElements("map", a[0].items);
        const pat = a[1].text;
        Value[] r;
        foreach (s; strs)
        {
            char[] o;
            size_t i = 0;
            while (i < pat.length)
            {
                if (pat[i] == '%')
                {
                    if (i + 1 < pat.length && pat[i + 1] == '%')
                    {
                        o ~= '%';
                        i += 2;
                    }
                    else
                    {
                        o ~= s;
                        ++i;
                    }
                }
                else
                {
                    o ~= pat[i];
                    ++i;
                }
            }
            r ~= V.ofStr(o.idup);
        }
        return V.ofList(r);
    });
    reg("filter", [T.list, T.str], (a, fs) => filterImpl("filter", a, true));
    reg("reject", [T.list, T.str], (a, fs) => filterImpl("reject", a, false));
    reg("sort", [T.list], (a, fs) {
        auto r = a[0].items.dup;
        r.sort!((x, y) => compareValues(x, y) < 0);
        return V.ofList(r);
    });
    reg("uniq", [T.list], (a, fs) {
        bool[string] seen;
        Value[] r;
        foreach (ref e; a[0].items)
        {
            const k = valueKey(e);
            if (k !in seen)
            {
                seen[k] = true;
                r ~= e;
            }
        }
        return V.ofList(r);
    });
    reg("reverse", [T.list], (a, fs) {
        auto r = a[0].items.dup;
        foreach (i; 0 .. r.length / 2)
        {
            auto t = r[i];
            r[i] = r[r.length - 1 - i];
            r[r.length - 1 - i] = t;
        }
        return V.ofList(r);
    });
    reg("first", [T.list], (a, fs) {
        if (a[0].items.length == 0)
            throw argError("first", "empty list");
        return a[0].items[0];
    });
    reg("last", [T.list], (a, fs) {
        if (a[0].items.length == 0)
            throw argError("last", "empty list");
        return a[0].items[$ - 1];
    });
    reg("slice", [T.list, T.int_, T.int_], (a, fs) {
        size_t s, c;
        clampRange(a[0].items.length, a[1].num, a[2].num, s, c);
        return V.ofList(a[0].items[s .. s + c]);
    });
    reg("has", [T.list, T.any], (a, fs) {
        foreach (ref e; a[0].items)
            if (valuesEqual(e, a[1]))
                return V.ofBool(true);
        return V.ofBool(false);
    });
    reg("indexof", [T.list, T.any], (a, fs) {
        foreach (i, ref e; a[0].items)
            if (valuesEqual(e, a[1]))
                return V.ofInt(cast(long) i);
        return V.ofInt(-1);
    });
    reg("range", [T.int_], (a, fs) {
        if (a[0].num < 0)
            throw argError("range", "negative");
        auto r = new Value[cast(size_t) a[0].num];
        foreach (i, ref e; r)
            e = V.ofInt(cast(long) i);
        return V.ofList(r);
    });
    reg("sum", [T.list], (a, fs) {
        long total = 0;
        foreach (i, ref e; a[0].items)
        {
            if (e.type != V.Type.integer)
                throw typeError("fn sum element " ~ i.to!string, "int", e.typeName);
            total += e.num;
        }
        return V.ofInt(total);
    });
    reg("flatten", [T.list], (a, fs) {
        Value[] r;
        foreach (ref e; a[0].items)
        {
            if (e.type == V.Type.list)
                r ~= e.items;
            else
                r ~= e;
        }
        return V.ofList(r);
    });
    reg("zip", [T.list, T.list], (a, fs) {
        const n = a[0].items.length < a[1].items.length ? a[0].items.length : a[1].items.length;
        auto r = new Value[n];
        foreach (i; 0 .. n)
            r[i] = V.ofList([a[0].items[i], a[1].items[i]]);
        return V.ofList(r);
    });
    reg("is_str", [T.any], (a, fs) => V.ofBool(a[0].type == V.Type.str));
    reg("is_int", [T.any], (a, fs) => V.ofBool(a[0].type == V.Type.integer));
    reg("is_bool", [T.any], (a, fs) => V.ofBool(a[0].type == V.Type.boolean));
    reg("is_list", [T.any], (a, fs) => V.ofBool(a[0].type == V.Type.list));
    reg("glob", [T.str], (a, fs) {
        GlobPattern pat;
        if (!GlobPattern.compile(a[0].text, pat))
            throw argError("glob", "bad pattern");
        Value[] r;
        foreach (p; fs.glob(pat))
            r ~= V.ofStr(p);
        return V.ofList(r);
    });
}

version (unittest)
{
    private Value call(string name, Value[] args, Vfs fs = null)
    {
        auto b = findBuiltin(name);
        assert(b !is null, name);
        checkCall(b, args);
        return b.run(args, fs);
    }

    private string errOf(string name, Value[] args)
    {
        try
        {
            call(name, args);
            return "ok";
        }
        catch (KilnError e)
            return e.msg;
    }

    private Value s(string x) { return Value.ofStr(x); }
    private Value n(long x) { return Value.ofInt(x); }
    private Value l(Value[] x...) { return Value.ofList(x.dup); }
}

unittest
{
    assert(builtinNames().length == 39);
}

unittest
{
    assert(call("substr", [s("abcdef"), n(1), n(3)]).text == "bcd");
    assert(call("substr", [s("abcdef"), n(-2), n(5)]).text == "ef");
    assert(call("substr", [s("abcdef"), n(10), n(2)]).text == "");
    assert(call("substr", [s("abcdef"), n(2), n(-1)]).text == "");
    assert(call("stem", [s("src/.hidden")]).text == ".hidden" && call("ext", [s("src/.hidden")]).text == "");
    assert(call("stem", [s("src/a.b.txt")]).text == "a.b" && call("ext", [s("src/x.")]).text == ".");
    assert(call("pathjoin", [s("out"), s(""), s("a.txt")]).text == "out/a.txt");
    assert(call("pathjoin", [s("out/")]).text == "out/");
    assert(call("map", [l(s("a")), s("100%%-%")]).items[0].text == "100%-a");
    assert(call("split", [s(""), s(",")]).items.length == 1);
    assert(call("join", [l(s("a"), n(2)), s("-")]).text == "a-2");
    assert(call("int", [s("-0042")]).num == -42);
    assert(call("int", [s("-9223372036854775808")]).num == long.min);
    assert(call("uniq", [l(n(1), s("1"), n(1))]).items.length == 2);
    assert(call("flatten", [l(l(n(1)), n(2))]).items.length == 2);
    assert(call("sum", [l()]).num == 0);
}

unittest
{
    assert(errOf("upper", [n(1)]) == "E_TYPE fn upper argument 1: expected str, got int");
    assert(errOf("upper", [s("a"), s("b")]) == "E_ARITY fn upper: expected 1, got 2");
    assert(errOf("pathjoin", []) == "E_ARITY fn pathjoin: expected 1-8, got 0");
    assert(errOf("int", [s("+1")]) == "E_ARG fn int: bad integer");
    assert(errOf("int", [s("9223372036854775808")]) == "E_ARG fn int: bad integer");
    assert(errOf("filter", [l(n(1)), s("")]) == "E_ARG fn filter: bad pattern");
    assert(errOf("filter", [l(n(1)), s("*")]) == "E_TYPE fn filter element 0: expected str, got int");
    assert(errOf("join", [l(l()), s("")]) == "E_TYPE fn join element 0: expected str|int, got list");
    assert(errOf("first", [l()]) == "E_ARG fn first: empty list");
    assert(errOf("range", [n(-1)]) == "E_ARG fn range: negative");
    assert(errOf("replace", [s("a"), s(""), s("b")]) == "E_ARG fn replace: empty pattern");
    assert(errOf("len", [n(1)]) == "E_TYPE fn len argument 1: expected str|list, got int");
}

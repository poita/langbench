/**
 * The 39 built-in functions of KBL.
 *
 * Calls go through $(LREF callBuiltin), which performs the arity check, the
 * argument type checks (in ascending argument order) and then runs the
 * function, so every function reports errors in the order the spec fixes.
 */
module kiln.builtins;

import kiln.bytes;
import kiln.errors;
import kiln.glob : GlobPattern, compileGlob;
import kiln.value;
import kiln.workspace : Workspace;

/// Expected type of a built-in's argument.
private enum ArgT : ubyte
{
    any,
    str,
    integer,
    boolean,
    list,
    strOrList,
    strOrInt,
    strIntBool,
}

private string expectedToken(ArgT t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ArgT.any:
        return "any";
    case ArgT.str:
        return "str";
    case ArgT.integer:
        return "int";
    case ArgT.boolean:
        return "bool";
    case ArgT.list:
        return "list";
    case ArgT.strOrList:
        return "str|list";
    case ArgT.strOrInt:
        return "str|int";
    case ArgT.strIntBool:
        return "str|int|bool";
    }
}

private bool accepts(ArgT t, ValueType v) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ArgT.any:
        return true;
    case ArgT.str:
        return v == ValueType.str;
    case ArgT.integer:
        return v == ValueType.integer;
    case ArgT.boolean:
        return v == ValueType.boolean;
    case ArgT.list:
        return v == ValueType.list;
    case ArgT.strOrList:
        return v == ValueType.str || v == ValueType.list;
    case ArgT.strOrInt:
        return v == ValueType.str || v == ValueType.integer;
    case ArgT.strIntBool:
        return v != ValueType.list;
    }
}

private alias Impl = Value function(Value[] a, Workspace ws) @safe;

/// A built-in function descriptor.
struct Builtin
{
    string name;
    private immutable(ArgT)[] types; // one per argument; the last repeats when variadic
    private size_t minArgs, maxArgs;
    private Impl impl;
}

private __gshared Builtin[string] table;

shared static this()
{
    Builtin[string] t;
    void add(string name, immutable(ArgT)[] types, Impl impl, size_t lo = size_t.max, size_t hi = size_t.max)
    {
        if (lo == size_t.max)
            lo = hi = types.length;
        t[name] = Builtin(name, types, lo, hi, impl);
    }

    alias A = ArgT;
    add("len", [A.strOrList], (a, ws) => Value.ofInt(a[0].type == ValueType.str ? a[0].s.length : a[0].l.length));
    add("count", [A.list], (a, ws) => Value.ofInt(a[0].l.length));
    add("upper", [A.str], (a, ws) => Value.ofStr(toUpperAscii(a[0].s)));
    add("lower", [A.str], (a, ws) => Value.ofStr(toLowerAscii(a[0].s)));
    add("trim", [A.str], &fnTrim);
    add("replace", [A.str, A.str, A.str], &fnReplace);
    add("starts_with", [A.str, A.str], (a, ws) => Value.ofBool(startsWith(a[0].s, a[1].s)));
    add("ends_with", [A.str, A.str], (a, ws) => Value.ofBool(endsWith(a[0].s, a[1].s)));
    add("contains", [A.str, A.str], (a, ws) => Value.ofBool(contains(a[0].s, a[1].s)));
    add("substr", [A.str, A.integer, A.integer], &fnSubstr);
    add("split", [A.str, A.str], &fnSplit);
    add("join", [A.list, A.str], &fnJoin);
    add("str", [A.strIntBool], (a, ws) => Value.ofStr(scalarText(a[0])));
    add("int", [A.strOrInt], &fnInt);
    add("dirname", [A.str], &fnDirname);
    add("basename", [A.str], (a, ws) => Value.ofStr(baseName(a[0].s)));
    add("stem", [A.str], &fnStem);
    add("ext", [A.str], &fnExt);
    add("pathjoin", [A.str], &fnPathjoin, 1, 8);
    add("map", [A.list, A.str], &fnMap);
    add("filter", [A.list, A.str], &fnFilter);
    add("reject", [A.list, A.str], &fnReject);
    add("sort", [A.list], &fnSort);
    add("uniq", [A.list], &fnUniq);
    add("reverse", [A.list], &fnReverse);
    add("first", [A.list], &fnFirst);
    add("last", [A.list], &fnLast);
    add("slice", [A.list, A.integer, A.integer], &fnSlice);
    add("has", [A.list, A.any], (a, ws) => Value.ofBool(indexIn(a[0].l, a[1]) >= 0));
    add("indexof", [A.list, A.any], (a, ws) => Value.ofInt(indexIn(a[0].l, a[1])));
    add("range", [A.integer], &fnRange);
    add("sum", [A.list], &fnSum);
    add("flatten", [A.list], &fnFlatten);
    add("zip", [A.list, A.list], &fnZip);
    add("is_str", [A.any], (a, ws) => Value.ofBool(a[0].type == ValueType.str));
    add("is_int", [A.any], (a, ws) => Value.ofBool(a[0].type == ValueType.integer));
    add("is_bool", [A.any], (a, ws) => Value.ofBool(a[0].type == ValueType.boolean));
    add("is_list", [A.any], (a, ws) => Value.ofBool(a[0].type == ValueType.list));
    add("glob", [A.str], &fnGlob);
    table = t;
}

/// The built-in called `name`, or null.
const(Builtin)* lookupBuiltin(const(char)[] name) @trusted
{
    return name in table;
}

/// The number of built-in functions.
size_t builtinCount() @trusted
{
    return table.length;
}

/**
 * Calls `fn` with already-evaluated `args`: arity, then argument types in
 * ascending order, then the function itself.
 */
Value callBuiltin(const(Builtin)* fn, Value[] args, Workspace ws) @safe
{
    if (args.length < fn.minArgs || args.length > fn.maxArgs)
    {
        auto expected = fn.minArgs == fn.maxArgs ? decimal(fn.minArgs)
            : decimal(fn.minArgs) ~ "-" ~ decimal(fn.maxArgs);
        fail("E_ARITY", "fn " ~ fn.name ~ ": expected " ~ expected ~ ", got " ~ decimal(args.length));
    }
    foreach (k, ref v; args)
    {
        immutable t = fn.types[k < fn.types.length ? k : fn.types.length - 1];
        if (!accepts(t, v.type))
            failType("fn " ~ fn.name ~ " argument " ~ decimal(k + 1), expectedToken(t), typeName(v));
    }
    return fn.impl(args, ws);
}

// ---- implementations ------------------------------------------------------

private bool isTrimByte(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

private Value fnTrim(Value[] a, Workspace) @safe
{
    auto s = a[0].s;
    size_t lo = 0, hi = s.length;
    while (lo < hi && isTrimByte(s[lo]))
        lo++;
    while (hi > lo && isTrimByte(s[hi - 1]))
        hi--;
    return Value.ofStr(s[lo .. hi]);
}

private Value fnReplace(Value[] a, Workspace) @safe
{
    if (a[1].s.length == 0)
        fail("E_ARG", "fn replace: empty pattern");
    return Value.ofStr(replaceAll(a[0].s, a[1].s, a[2].s));
}

/// Clamps `(start, count)` against a sequence of length `n`, per `substr`.
private void clampRange(long n, long start, long count, out size_t lo, out size_t len) @safe pure nothrow @nogc
{
    if (start < 0)
        start = n + start;
    if (start < 0)
        start = 0;
    if (start > n)
        start = n;
    if (count < 0)
        count = 0;
    if (count > n - start)
        count = n - start;
    lo = cast(size_t) start;
    len = cast(size_t) count;
}

private Value fnSubstr(Value[] a, Workspace) @safe
{
    size_t lo, len;
    clampRange(a[0].s.length, a[1].i, a[2].i, lo, len);
    return Value.ofStr(a[0].s[lo .. lo + len]);
}

private Value fnSlice(Value[] a, Workspace) @safe
{
    size_t lo, len;
    clampRange(a[0].l.length, a[1].i, a[2].i, lo, len);
    return Value.ofList(a[0].l[lo .. lo + len]);
}

private Value fnSplit(Value[] a, Workspace) @safe
{
    auto s = a[0].s, sep = a[1].s;
    if (sep.length == 0)
        fail("E_ARG", "fn split: empty separator");
    Value[] parts;
    size_t cur = 0;
    while (true)
    {
        immutable pos = indexOf(s, sep, cur);
        if (pos < 0)
            break;
        parts ~= Value.ofStr(s[cur .. pos]);
        cur = pos + sep.length;
    }
    parts ~= Value.ofStr(s[cur .. $]);
    return Value.ofList(parts);
}

private Value fnJoin(Value[] a, Workspace) @safe
{
    char[] buf;
    foreach (k, ref e; a[0].l)
    {
        if (e.type != ValueType.str && e.type != ValueType.integer)
            failType("fn join element " ~ decimal(k), "str|int", typeName(e));
        if (k)
            buf ~= a[1].s;
        buf ~= scalarText(e);
    }
    return Value.ofStr((() @trusted => cast(string) buf)());
}

private Value fnInt(Value[] a, Workspace) @safe
{
    if (a[0].type == ValueType.integer)
        return a[0];
    auto s = a[0].s;
    immutable neg = s.length > 0 && s[0] == '-';
    auto digits = neg ? s[1 .. $] : s;
    if (digits.length == 0)
        fail("E_ARG", "fn int: bad integer");
    ulong v = 0;
    immutable limit = neg ? (cast(ulong) long.max) + 1 : cast(ulong) long.max;
    foreach (c; digits)
    {
        if (c < '0' || c > '9')
            fail("E_ARG", "fn int: bad integer");
        immutable d = c - '0';
        if (v > (limit - d) / 10)
            fail("E_ARG", "fn int: bad integer");
        v = v * 10 + d;
    }
    return Value.ofInt(neg ? cast(long)(0 - v) : cast(long) v);
}

private string baseName(string s) @safe pure nothrow @nogc
{
    foreach_reverse (i; 0 .. s.length)
        if (s[i] == '/')
            return s[i + 1 .. $];
    return s;
}

private Value fnDirname(Value[] a, Workspace) @safe
{
    auto s = a[0].s;
    foreach_reverse (i; 0 .. s.length)
        if (s[i] == '/')
            return Value.ofStr(s[0 .. i]);
    return Value.ofStr("");
}

/// Index of the extension's dot in a basename, or -1.
private ptrdiff_t dotIndex(string b) @safe pure nothrow @nogc
{
    foreach_reverse (i; 1 .. b.length)
        if (b[i] == '.')
            return cast(ptrdiff_t) i;
    return -1;
}

private Value fnStem(Value[] a, Workspace) @safe
{
    auto b = baseName(a[0].s);
    immutable d = dotIndex(b);
    return Value.ofStr(d < 0 ? b : b[0 .. d]);
}

private Value fnExt(Value[] a, Workspace) @safe
{
    auto b = baseName(a[0].s);
    immutable d = dotIndex(b);
    return Value.ofStr(d < 0 ? "" : b[d .. $]);
}

private Value fnPathjoin(Value[] a, Workspace) @safe
{
    char[] buf;
    bool any = false;
    foreach (ref e; a)
    {
        if (e.s.length == 0)
            continue;
        if (any)
            buf ~= '/';
        buf ~= e.s;
        any = true;
    }
    return Value.ofStr((() @trusted => cast(string) buf)());
}

private Value fnMap(Value[] a, Workspace) @safe
{
    auto pat = a[1].s;
    auto result = new Value[a[0].l.length];
    foreach (k, ref e; a[0].l)
    {
        if (e.type != ValueType.str)
            failType("fn map element " ~ decimal(k), "str", typeName(e));
        char[] buf;
        size_t i = 0;
        while (i < pat.length)
        {
            if (pat[i] == '%')
            {
                if (i + 1 < pat.length && pat[i + 1] == '%')
                {
                    buf ~= '%';
                    i += 2;
                }
                else
                {
                    buf ~= e.s;
                    i++;
                }
            }
            else
            {
                buf ~= pat[i];
                i++;
            }
        }
        result[k] = Value.ofStr((() @trusted => cast(string) buf)());
    }
    return Value.ofList(result);
}

private Value filterImpl(Value[] a, string name, bool keepMatches) @safe
{
    GlobPattern gp;
    if (!compileGlob(a[1].s, gp))
        fail("E_ARG", "fn " ~ name ~ ": bad pattern");
    Value[] kept;
    foreach (k, ref e; a[0].l)
    {
        if (e.type != ValueType.str)
            failType("fn " ~ name ~ " element " ~ decimal(k), "str", typeName(e));
        if (gp.matches(e.s) == keepMatches)
            kept ~= e;
    }
    return Value.ofList(kept);
}

private Value fnFilter(Value[] a, Workspace) @safe
{
    return filterImpl(a, "filter", true);
}

private Value fnReject(Value[] a, Workspace) @safe
{
    return filterImpl(a, "reject", false);
}

private Value fnSort(Value[] a, Workspace) @safe
{
    import std.algorithm.sorting : sort;

    auto items = a[0].l.dup;
    items.sort!((x, y) => compareValues(x, y) < 0);
    return Value.ofList(items);
}

private Value fnUniq(Value[] a, Workspace) @safe
{
    bool[string] seen;
    Value[] kept;
    char[] key;
    foreach (ref e; a[0].l)
    {
        key.length = 0;
        appendKey(key, e);
        string k = key.idup;
        if (k in seen)
            continue;
        seen[k] = true;
        kept ~= e;
    }
    return Value.ofList(kept);
}

private Value fnReverse(Value[] a, Workspace) @safe
{
    auto n = a[0].l.length;
    auto r = new Value[n];
    foreach (k; 0 .. n)
        r[k] = a[0].l[n - 1 - k];
    return Value.ofList(r);
}

private Value fnFirst(Value[] a, Workspace) @safe
{
    if (a[0].l.length == 0)
        fail("E_ARG", "fn first: empty list");
    return a[0].l[0];
}

private Value fnLast(Value[] a, Workspace) @safe
{
    if (a[0].l.length == 0)
        fail("E_ARG", "fn last: empty list");
    return a[0].l[$ - 1];
}

private long indexIn(const(Value)[] items, in Value needle) @safe pure nothrow
{
    foreach (k, ref e; items)
        if (valuesEqual(e, needle))
            return cast(long) k;
    return -1;
}

private Value fnRange(Value[] a, Workspace) @safe
{
    if (a[0].i < 0)
        fail("E_ARG", "fn range: negative");
    auto r = new Value[cast(size_t) a[0].i];
    foreach (k; 0 .. r.length)
        r[k] = Value.ofInt(cast(long) k);
    return Value.ofList(r);
}

private Value fnSum(Value[] a, Workspace) @safe
{
    long total = 0;
    foreach (k, ref e; a[0].l)
    {
        if (e.type != ValueType.integer)
            failType("fn sum element " ~ decimal(k), "int", typeName(e));
        total += e.i;
    }
    return Value.ofInt(total);
}

private Value fnFlatten(Value[] a, Workspace) @safe
{
    Value[] r;
    foreach (ref e; a[0].l)
    {
        if (e.type == ValueType.list)
            r ~= e.l;
        else
            r ~= e;
    }
    return Value.ofList(r);
}

private Value fnZip(Value[] a, Workspace) @safe
{
    immutable n = a[0].l.length < a[1].l.length ? a[0].l.length : a[1].l.length;
    auto r = new Value[n];
    foreach (k; 0 .. n)
        r[k] = Value.ofList([a[0].l[k], a[1].l[k]]);
    return Value.ofList(r);
}

private Value fnGlob(Value[] a, Workspace ws) @safe
{
    GlobPattern gp;
    if (!compileGlob(a[0].s, gp))
        fail("E_ARG", "fn glob: bad pattern");
    return Value.ofStrings(ws.glob(gp));
}

@safe unittest
{
    import std.exception : collectException;

    assert(builtinCount == 39);
    auto ws = new Workspace;
    Value call(string name, Value[] args...)
    {
        return callBuiltin(lookupBuiltin(name), args.dup, ws);
    }

    auto S(string s) => Value.ofStr(s);
    auto I(long i) => Value.ofInt(i);
    assert(call("substr", S("abcdef"), I(1), I(3)).s == "bcd");
    assert(call("substr", S("abcdef"), I(-2), I(5)).s == "ef");
    assert(call("substr", S("abcdef"), I(10), I(2)).s == "");
    assert(call("substr", S("abcdef"), I(2), I(-1)).s == "");
    assert(call("split", S("a,,b"), S(",")).l.length == 3);
    assert(call("split", S(""), S(",")).l.length == 1);
    assert(call("stem", S("src/.hidden")).s == ".hidden" && call("ext", S("src/x.")).s == ".");
    assert(call("stem", S("src/a.b.txt")).s == "a.b" && call("ext", S("src/a.b.txt")).s == ".txt");
    assert(call("pathjoin", S("out"), S(""), S("a.txt")).s == "out/a.txt");
    assert(call("pathjoin", S("out/")).s == "out/");
    assert(call("map", Value.ofStrings(["a"]), S("100%%-%")).l[0].s == "100%-a");
    assert(call("int", S("-0012")).i == -12);
    assert(call("int", I(5)).i == 5);
    auto e = collectException!KilnError(call("int", S("9223372036854775808")));
    assert(e && e.detail == "fn int: bad integer");
    assert(call("int", S("-9223372036854775808")).i == long.min);
    e = collectException!KilnError(call("upper", S("a"), S("b")));
    assert(e && e.detail == "fn upper: expected 1, got 2");
    e = collectException!KilnError(call("pathjoin"));
    assert(e && e.detail == "fn pathjoin: expected 1-8, got 0");
    e = collectException!KilnError(call("upper", I(1)));
    assert(e && e.detail == "fn upper argument 1: expected str, got int");
    e = collectException!KilnError(call("filter", Value.ofList([I(1)]), S("")));
    assert(e && e.detail == "fn filter: bad pattern");
    assert(call("uniq", Value.ofList([I(1), S("1"), I(1)])).l.length == 2);
    assert(call("sort", Value.ofList([S("b"), I(2), Value.ofBool(true), S("a")])).l[3].s == "b");
    assert(call("flatten", Value.ofList([Value.ofList([I(1)]), I(2)])).l.length == 2);
    assert(call("trim", S(" \t\r\nx y\n")).s == "x y");
}

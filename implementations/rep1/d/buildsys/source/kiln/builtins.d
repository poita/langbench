/// The 39 KBL built-in functions.
module kiln.builtins;

import std.algorithm.sorting : sort;

import kiln.bytes;
import kiln.errors;
import kiln.glob;
import kiln.value;
import kiln.vfs;

/// Bit for each value type, used in argument type masks.
enum ubyte tBool = 1, tInt = 2, tStr = 4, tList = 8, tAny = 0;

/// Signature of a built-in implementation; arguments are already type-checked.
alias BuiltinFn = Value function(Vfs vfs, Value[] a) @safe;

/// A built-in function descriptor.
struct Builtin
{
    string name;
    int minArgs;
    int maxArgs;
    ubyte[] masks; /// allowed types per argument; the last entry repeats
    BuiltinFn fn;
}

private Builtin[string] table;

/// Looks up a built-in by name; null if there is none.
const(Builtin)* findBuiltin(const(char)[] name) @safe
{
    if (auto p = name in table)
        return p;
    return null;
}

/// The text of a `str`, `int` or `bool` value, as interpolation renders it.
string textOf(const ref Value v) @safe
{
    final switch (v.type)
    {
    case Value.Type.str:
        return v.s;
    case Value.Type.integer:
        return decimal(v.num);
    case Value.Type.boolean:
        return v.num ? "true" : "false";
    case Value.Type.list:
        assert(false, "lists have no text form");
    }
}

/// The type token naming an allowed-type mask, e.g. `str|list`.
string maskName(ubyte m) @safe
{
    string r;
    void add(string s)
    {
        r = r.length ? r ~ "|" ~ s : s;
    }

    if (m & tStr)
        add("str");
    if (m & tInt)
        add("int");
    if (m & tBool)
        add("bool");
    if (m & tList)
        add("list");
    return r;
}

private string str_(const ref Value v) @safe
{
    return v.s;
}

private ubyte[] M(ubyte[] m...) pure nothrow @safe
{
    return m.dup;
}

shared static this()
{
    Builtin[string] t;
    void reg(string name, int lo, int hi, ubyte[] masks, BuiltinFn fn)
    {
        t[name] = Builtin(name, lo, hi, masks, fn);
    }

    reg("len", 1, 1, M(tStr | tList), &fnLen);
    reg("count", 1, 1, M(tList), &fnLen);
    reg("upper", 1, 1, M(tStr), &fnUpper);
    reg("lower", 1, 1, M(tStr), &fnLower);
    reg("trim", 1, 1, M(tStr), &fnTrim);
    reg("replace", 3, 3, M(tStr), &fnReplace);
    reg("starts_with", 2, 2, M(tStr), &fnStartsWith);
    reg("ends_with", 2, 2, M(tStr), &fnEndsWith);
    reg("contains", 2, 2, M(tStr), &fnContains);
    reg("substr", 3, 3, M(tStr, tInt, tInt), &fnSubstr);
    reg("split", 2, 2, M(tStr), &fnSplit);
    reg("join", 2, 2, M(tList, tStr), &fnJoin);
    reg("str", 1, 1, M(tStr | tInt | tBool), &fnStr);
    reg("int", 1, 1, M(tStr | tInt), &fnInt);
    reg("dirname", 1, 1, M(tStr), &fnDirname);
    reg("basename", 1, 1, M(tStr), &fnBasename);
    reg("stem", 1, 1, M(tStr), &fnStem);
    reg("ext", 1, 1, M(tStr), &fnExt);
    reg("pathjoin", 1, 8, M(tStr), &fnPathjoin);
    reg("map", 2, 2, M(tList, tStr), &fnMap);
    reg("filter", 2, 2, M(tList, tStr), &fnFilter);
    reg("reject", 2, 2, M(tList, tStr), &fnReject);
    reg("sort", 1, 1, M(tList), &fnSort);
    reg("uniq", 1, 1, M(tList), &fnUniq);
    reg("reverse", 1, 1, M(tList), &fnReverse);
    reg("first", 1, 1, M(tList), &fnFirst);
    reg("last", 1, 1, M(tList), &fnLast);
    reg("slice", 3, 3, M(tList, tInt, tInt), &fnSlice);
    reg("has", 2, 2, M(tList, tAny), &fnHas);
    reg("indexof", 2, 2, M(tList, tAny), &fnIndexof);
    reg("range", 1, 1, M(tInt), &fnRange);
    reg("sum", 1, 1, M(tList), &fnSum);
    reg("flatten", 1, 1, M(tList), &fnFlatten);
    reg("zip", 2, 2, M(tList), &fnZip);
    reg("is_str", 1, 1, M(tAny), &fnIsStr);
    reg("is_int", 1, 1, M(tAny), &fnIsInt);
    reg("is_bool", 1, 1, M(tAny), &fnIsBool);
    reg("is_list", 1, 1, M(tAny), &fnIsList);
    reg("glob", 1, 1, M(tStr), &fnGlob);
    table = t;
}

private:

alias V = Value;

V fnLen(Vfs, V[] a) @safe
{
    return V.ofInt(a[0].type == V.Type.str ? cast(long) a[0].s.length : cast(long) a[0].items.length);
}

V fnUpper(Vfs, V[] a) @safe
{
    auto s = a[0].s;
    char[] r = new char[s.length];
    foreach (i; 0 .. s.length)
        r[i] = (s[i] >= 'a' && s[i] <= 'z') ? cast(char)(s[i] - 32) : s[i];
    return V.ofStr((() @trusted => cast(string) r)());
}

V fnLower(Vfs, V[] a) @safe
{
    auto s = a[0].s;
    char[] r = new char[s.length];
    foreach (i; 0 .. s.length)
        r[i] = (s[i] >= 'A' && s[i] <= 'Z') ? cast(char)(s[i] + 32) : s[i];
    return V.ofStr((() @trusted => cast(string) r)());
}

V fnTrim(Vfs, V[] a) @safe
{
    auto s = a[0].s;
    bool ws(char c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
    size_t b = 0, e = s.length;
    while (b < e && ws(s[b]))
        ++b;
    while (e > b && ws(s[e - 1]))
        --e;
    return V.ofStr(s[b .. e]);
}

V fnReplace(Vfs, V[] a) @safe
{
    if (a[1].s.length == 0)
        throw argError("fn", "replace", "empty pattern");
    return V.ofStr(replaceAll(a[0].s, a[1].s, a[2].s));
}

V fnStartsWith(Vfs, V[] a) @safe
{
    return V.ofBool(a[0].s.length >= a[1].s.length && a[0].s[0 .. a[1].s.length] == a[1].s);
}

V fnEndsWith(Vfs, V[] a) @safe
{
    return V.ofBool(a[0].s.length >= a[1].s.length && a[0].s[$ - a[1].s.length .. $] == a[1].s);
}

V fnContains(Vfs, V[] a) @safe
{
    return V.ofBool(containsBytes(a[0].s, a[1].s));
}

/// Clamps `(start, count)` against length `n` per the substr/slice rules.
private void clampRange(long n, long start, long count, out size_t b, out size_t len) pure nothrow @safe
{
    if (start < 0)
        start += n;
    if (start < 0)
        start = 0;
    if (start > n)
        start = n;
    if (count < 0)
        count = 0;
    if (count > n - start)
        count = n - start;
    b = cast(size_t) start;
    len = cast(size_t) count;
}

V fnSubstr(Vfs, V[] a) @safe
{
    size_t b, l;
    clampRange(cast(long) a[0].s.length, a[1].num, a[2].num, b, l);
    return V.ofStr(a[0].s[b .. b + l]);
}

V fnSplit(Vfs, V[] a) @safe
{
    const s = a[0].s, sep = a[1].s;
    if (sep.length == 0)
        throw argError("fn", "split", "empty separator");
    V[] r;
    size_t i = 0;
    while (true)
    {
        const j = findBytes(s, sep, i);
        if (j == size_t.max)
            break;
        r ~= V.ofStr(a[0].s[i .. j]);
        i = j + sep.length;
    }
    r ~= V.ofStr(a[0].s[i .. $]);
    return V.ofList(r);
}

V fnJoin(Vfs, V[] a) @safe
{
    char[] r;
    foreach (i, ref e; a[0].items)
    {
        if (e.type != V.Type.str && e.type != V.Type.integer)
            throw typeError("fn join element " ~ decimal(cast(long) i), "str|int", e.typeName);
        if (i)
            r ~= a[1].s;
        r ~= textOf(e);
    }
    return V.ofStr((() @trusted => cast(string) r)());
}

V fnStr(Vfs, V[] a) @safe
{
    return V.ofStr(textOf(a[0]));
}

V fnInt(Vfs, V[] a) @safe
{
    if (a[0].type == V.Type.integer)
        return a[0];
    const s = a[0].s;
    size_t i = 0;
    bool neg = false;
    if (s.length && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i >= s.length)
        throw argError("fn", "int", "bad integer");
    const ulong limit = neg ? (1UL << 63) : (1UL << 63) - 1;
    ulong acc = 0;
    for (; i < s.length; ++i)
    {
        if (s[i] < '0' || s[i] > '9')
            throw argError("fn", "int", "bad integer");
        const d = cast(ulong)(s[i] - '0');
        if (acc > (limit - d) / 10)
            throw argError("fn", "int", "bad integer");
        acc = acc * 10 + d;
    }
    return V.ofInt(neg ? cast(long)(0 - acc) : cast(long) acc);
}

private size_t lastSlash(const(char)[] s) pure nothrow @safe
{
    foreach_reverse (i; 0 .. s.length)
        if (s[i] == '/')
            return i;
    return size_t.max;
}

private string baseOf(string s) pure nothrow @safe
{
    const k = lastSlash(s);
    return k == size_t.max ? s : s[k + 1 .. $];
}

V fnDirname(Vfs, V[] a) @safe
{
    const k = lastSlash(a[0].s);
    return V.ofStr(k == size_t.max ? "" : a[0].s[0 .. k]);
}

V fnBasename(Vfs, V[] a) @safe
{
    return V.ofStr(baseOf(a[0].s));
}

private size_t extStart(const(char)[] b) pure nothrow @safe
{
    foreach_reverse (i; 1 .. b.length)
        if (b[i] == '.')
            return i;
    return size_t.max;
}

V fnStem(Vfs, V[] a) @safe
{
    const b = baseOf(a[0].s);
    const k = extStart(b);
    return V.ofStr(k == size_t.max ? b : b[0 .. k]);
}

V fnExt(Vfs, V[] a) @safe
{
    const b = baseOf(a[0].s);
    const k = extStart(b);
    return V.ofStr(k == size_t.max ? "" : b[k .. $]);
}

V fnPathjoin(Vfs, V[] a) @safe
{
    char[] r;
    bool first = true;
    foreach (ref e; a)
    {
        if (e.s.length == 0)
            continue;
        if (!first)
            r ~= '/';
        r ~= e.s;
        first = false;
    }
    return V.ofStr((() @trusted => cast(string) r)());
}

V fnMap(Vfs, V[] a) @safe
{
    V[] r;
    r.reserve(a[0].items.length);
    const pat = a[1].s;
    foreach (i, ref e; a[0].items)
    {
        if (e.type != V.Type.str)
            throw typeError("fn map element " ~ decimal(cast(long) i), "str", e.typeName);
        char[] b;
        size_t k = 0;
        while (k < pat.length)
        {
            if (pat[k] == '%')
            {
                if (k + 1 < pat.length && pat[k + 1] == '%')
                {
                    b ~= '%';
                    k += 2;
                }
                else
                {
                    b ~= e.s;
                    ++k;
                }
            }
            else
            {
                b ~= pat[k];
                ++k;
            }
        }
        r ~= V.ofStr((() @trusted => cast(string) b)());
    }
    return V.ofList(r);
}

private V filterImpl(V[] a, bool keepMatching, string fname) @safe
{
    auto g = GlobPattern.compile(a[1].s);
    if (g is null)
        throw argError("fn", fname, "bad pattern");
    V[] r;
    foreach (i, ref e; a[0].items)
    {
        if (e.type != V.Type.str)
            throw typeError("fn " ~ fname ~ " element " ~ decimal(cast(long) i), "str", e.typeName);
        if (g.matches(e.s) == keepMatching)
            r ~= e;
    }
    return V.ofList(r);
}

V fnFilter(Vfs, V[] a) @safe
{
    return filterImpl(a, true, "filter");
}

V fnReject(Vfs, V[] a) @safe
{
    return filterImpl(a, false, "reject");
}

V fnSort(Vfs, V[] a) @safe
{
    auto r = a[0].items.dup;
    r.sort!((x, y) => compareValues(x, y) < 0);
    return V.ofList(r);
}

V fnUniq(Vfs, V[] a) @safe
{
    V[] r;
    bool[string] seen;
    foreach (ref e; a[0].items)
    {
        if (e.type == V.Type.str)
        {
            if (e.s in seen)
                continue;
            seen[e.s] = true;
            r ~= e;
        }
        else
        {
            bool dup = false;
            foreach (ref o; r)
                if (valuesEqual(o, e))
                {
                    dup = true;
                    break;
                }
            if (!dup)
                r ~= e;
        }
    }
    return V.ofList(r);
}

V fnReverse(Vfs, V[] a) @safe
{
    auto r = a[0].items.dup;
    foreach (i; 0 .. r.length / 2)
    {
        auto t = r[i];
        r[i] = r[r.length - 1 - i];
        r[r.length - 1 - i] = t;
    }
    return V.ofList(r);
}

V fnFirst(Vfs, V[] a) @safe
{
    if (a[0].items.length == 0)
        throw argError("fn", "first", "empty list");
    return a[0].items[0];
}

V fnLast(Vfs, V[] a) @safe
{
    if (a[0].items.length == 0)
        throw argError("fn", "last", "empty list");
    return a[0].items[$ - 1];
}

V fnSlice(Vfs, V[] a) @safe
{
    size_t b, l;
    clampRange(cast(long) a[0].items.length, a[1].num, a[2].num, b, l);
    return V.ofList(a[0].items[b .. b + l]);
}

V fnHas(Vfs, V[] a) @safe
{
    foreach (ref e; a[0].items)
        if (valuesEqual(e, a[1]))
            return V.ofBool(true);
    return V.ofBool(false);
}

V fnIndexof(Vfs, V[] a) @safe
{
    foreach (i, ref e; a[0].items)
        if (valuesEqual(e, a[1]))
            return V.ofInt(cast(long) i);
    return V.ofInt(-1);
}

V fnRange(Vfs, V[] a) @safe
{
    if (a[0].num < 0)
        throw argError("fn", "range", "negative");
    V[] r;
    r.reserve(cast(size_t) a[0].num);
    foreach (i; 0 .. a[0].num)
        r ~= V.ofInt(i);
    return V.ofList(r);
}

V fnSum(Vfs, V[] a) @safe
{
    long s = 0;
    foreach (i, ref e; a[0].items)
    {
        if (e.type != V.Type.integer)
            throw typeError("fn sum element " ~ decimal(cast(long) i), "int", e.typeName);
        s += e.num;
    }
    return V.ofInt(s);
}

V fnFlatten(Vfs, V[] a) @safe
{
    V[] r;
    foreach (ref e; a[0].items)
    {
        if (e.type == V.Type.list)
            r ~= e.items;
        else
            r ~= e;
    }
    return V.ofList(r);
}

V fnZip(Vfs, V[] a) @safe
{
    const n = a[0].items.length < a[1].items.length ? a[0].items.length : a[1].items.length;
    V[] r;
    r.reserve(n);
    foreach (i; 0 .. n)
        r ~= V.ofList([a[0].items[i], a[1].items[i]]);
    return V.ofList(r);
}

V fnIsStr(Vfs, V[] a) @safe
{
    return V.ofBool(a[0].type == V.Type.str);
}

V fnIsInt(Vfs, V[] a) @safe
{
    return V.ofBool(a[0].type == V.Type.integer);
}

V fnIsBool(Vfs, V[] a) @safe
{
    return V.ofBool(a[0].type == V.Type.boolean);
}

V fnIsList(Vfs, V[] a) @safe
{
    return V.ofBool(a[0].type == V.Type.list);
}

V fnGlob(Vfs vfs, V[] a) @safe
{
    auto g = GlobPattern.compile(a[0].s);
    if (g is null)
        throw argError("fn", "glob", "bad pattern");
    V[] r;
    foreach (p; vfs.globRange(g.literalPrefix))
        if (g.matches(p))
            r ~= V.ofStr(p);
    return V.ofList(r);
}

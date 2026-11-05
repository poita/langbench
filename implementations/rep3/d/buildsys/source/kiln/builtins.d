/// The 39 built-in functions of KBL.
module kiln.builtins;

import std.algorithm.sorting : sort;
import kiln.bytes;
import kiln.errors;
import kiln.glob;
import kiln.value;
import kiln.vfs : Vfs;

private enum T : ubyte { any, str, integer, list, strOrList, strOrInt, scalar }

private string expectedName(T t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case T.any: return "any";
    case T.str: return "str";
    case T.integer: return "int";
    case T.list: return "list";
    case T.strOrList: return "str|list";
    case T.strOrInt: return "str|int";
    case T.scalar: return "str|int|bool";
    }
}

private bool typeOk(T t, VKind k) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case T.any: return true;
    case T.str: return k == VKind.str;
    case T.integer: return k == VKind.integer;
    case T.list: return k == VKind.list;
    case T.strOrList: return k == VKind.str || k == VKind.list;
    case T.strOrInt: return k == VKind.str || k == VKind.integer;
    case T.scalar: return k != VKind.list;
    }
}

private alias Impl = Value function(Vfs vfs, Value[] a);

private struct Builtin
{
    string name;
    ubyte minArgs, maxArgs;
    T[] types;
    Impl impl;
}

private Value S(string s) @safe pure nothrow { return Value.ofStr(s); }
private Value I(long n) @safe pure nothrow { return Value.ofInt(n); }
private Value B(bool b) @safe pure nothrow { return Value.ofBool(b); }
private Value L(Value[] l) @safe pure nothrow { return Value.ofList(l); }

private Builtin fixed(string name, T[] types, Impl impl)
{
    return Builtin(name, cast(ubyte) types.length, cast(ubyte) types.length, types, impl);
}

private immutable(Builtin)[] table;
private int[string] tableIndex;

shared static this()
{
    Builtin[] t = [
        fixed("len", [T.strOrList], (v, a) => I(a[0].isStr ? a[0].s.length : a[0].items.length)),
        fixed("count", [T.list], (v, a) => I(a[0].items.length)),
        fixed("upper", [T.str], (v, a) => S(mapBytes(a[0].s, 'a', 'z', -32))),
        fixed("lower", [T.str], (v, a) => S(mapBytes(a[0].s, 'A', 'Z', 32))),
        fixed("trim", [T.str], (v, a) => S(trimBytes(a[0].s))),
        fixed("replace", [T.str, T.str, T.str], &fnReplace),
        fixed("starts_with", [T.str, T.str], (v, a) => B(startsWithBytes(a[0].s, a[1].s))),
        fixed("ends_with", [T.str, T.str], (v, a) => B(endsWithBytes(a[0].s, a[1].s))),
        fixed("contains", [T.str, T.str], (v, a) => B(findBytes(a[0].s, a[1].s) != size_t.max)),
        fixed("substr", [T.str, T.integer, T.integer], &fnSubstr),
        fixed("split", [T.str, T.str], &fnSplit),
        fixed("join", [T.list, T.str], &fnJoin),
        fixed("str", [T.scalar], (v, a) => S(interpolatedText(a[0]))),
        fixed("int", [T.strOrInt], &fnInt),
        fixed("dirname", [T.str], (v, a) => S(dirnameOf(a[0].s))),
        fixed("basename", [T.str], (v, a) => S(basenameOf(a[0].s))),
        fixed("stem", [T.str], (v, a) => S(stemOf(a[0].s))),
        fixed("ext", [T.str], (v, a) => S(extOf(a[0].s))),
        Builtin("pathjoin", 1, 8, [T.str, T.str, T.str, T.str, T.str, T.str, T.str, T.str], &fnPathjoin),
        fixed("map", [T.list, T.str], &fnMap),
        fixed("filter", [T.list, T.str], &fnFilter),
        fixed("reject", [T.list, T.str], &fnReject),
        fixed("sort", [T.list], &fnSort),
        fixed("uniq", [T.list], &fnUniq),
        fixed("reverse", [T.list], &fnReverse),
        fixed("first", [T.list], &fnFirst),
        fixed("last", [T.list], &fnLast),
        fixed("slice", [T.list, T.integer, T.integer], &fnSlice),
        fixed("has", [T.list, T.any], (v, a) => B(indexIn(a[0].items, a[1]) >= 0)),
        fixed("indexof", [T.list, T.any], (v, a) => I(indexIn(a[0].items, a[1]))),
        fixed("range", [T.integer], &fnRange),
        fixed("sum", [T.list], &fnSum),
        fixed("flatten", [T.list], &fnFlatten),
        fixed("zip", [T.list, T.list], &fnZip),
        fixed("is_str", [T.any], (v, a) => B(a[0].isStr)),
        fixed("is_int", [T.any], (v, a) => B(a[0].isInt)),
        fixed("is_bool", [T.any], (v, a) => B(a[0].isBool)),
        fixed("is_list", [T.any], (v, a) => B(a[0].isList)),
        fixed("glob", [T.str], &fnGlob),
    ];
    table = cast(immutable(Builtin)[]) t;
    foreach (i, ref b; table)
        tableIndex[b.name] = cast(int) i;
}

/// Index of the built-in called `name`, or -1.
int builtinIndex(string name)
{
    if (auto p = name in tableIndex)
        return *p;
    return -1;
}

/// Name of the built-in at `idx`.
string builtinName(int idx)
{
    return table[idx].name;
}

/// Number of built-in functions.
size_t builtinCount()
{
    return table.length;
}

/// Call built-in `idx` with already-evaluated arguments: arity check, type
/// check in ascending argument order, then the function itself.
Value callBuiltin(int idx, Value[] args, Vfs vfs)
{
    ref const b = table[idx];
    if (args.length < b.minArgs || args.length > b.maxArgs)
    {
        string expected = b.minArgs == b.maxArgs ? intText(b.minArgs) : intText(b.minArgs) ~ "-" ~ intText(b.maxArgs);
        throw new KilnError("E_ARITY", "fn " ~ b.name ~ ": expected " ~ expected ~ ", got " ~ intText(args.length));
    }
    foreach (i, ref a; args)
        if (!typeOk(b.types[i], a.kind))
            throw typeError("fn " ~ b.name ~ " argument " ~ intText(i + 1), expectedName(b.types[i]), typeName(a.kind));
    return b.impl(vfs, args);
}

// ---------------------------------------------------------------- helpers

private string mapBytes(string s, char lo, char hi, int delta)
{
    bool any = false;
    foreach (c; s)
        if (c >= lo && c <= hi)
        {
            any = true;
            break;
        }
    if (!any)
        return s;
    auto r = new char[s.length];
    foreach (i, c; s)
        r[i] = (c >= lo && c <= hi) ? cast(char)(c + delta) : c;
    return cast(string) r;
}

private string trimBytes(string s)
{
    static bool ws(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
    size_t a = 0, b = s.length;
    while (a < b && ws(s[a]))
        ++a;
    while (b > a && ws(s[b - 1]))
        --b;
    return s[a .. b];
}

/// Text before the last `/`, or "".
string dirnameOf(string p)
{
    foreach_reverse (i; 0 .. p.length)
        if (p[i] == '/')
            return p[0 .. i];
    return "";
}

/// Text after the last `/`, or the whole string.
string basenameOf(string p)
{
    foreach_reverse (i; 0 .. p.length)
        if (p[i] == '/')
            return p[i + 1 .. $];
    return p;
}

private size_t extStart(string b)
{
    foreach_reverse (i; 1 .. b.length)
        if (b[i] == '.')
            return i;
    return size_t.max;
}

private string stemOf(string p)
{
    auto b = basenameOf(p);
    auto i = extStart(b);
    return i == size_t.max ? b : b[0 .. i];
}

private string extOf(string p)
{
    auto b = basenameOf(p);
    auto i = extStart(b);
    return i == size_t.max ? "" : b[i .. $];
}

private long indexIn(const(Value)[] items, const ref Value v)
{
    foreach (i, ref it; items)
        if (valuesEqual(it, v))
            return cast(long) i;
    return -1;
}

private void clampRange(long n, long start, long count, out size_t s, out size_t c)
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
    s = cast(size_t) start;
    c = cast(size_t) count;
}

private void keyOf(ref Buf b, const ref Value v)
{
    final switch (v.kind)
    {
    case VKind.boolean:
        b.put(v.num ? "b1;" : "b0;");
        break;
    case VKind.integer:
        b.putc('i');
        b.putInt(v.num);
        b.putc(';');
        break;
    case VKind.str:
        b.putc('s');
        b.putInt(v.s.length);
        b.putc(':');
        b.put(v.s);
        break;
    case VKind.list:
        b.putc('[');
        b.putInt(v.items.length);
        b.putc(':');
        foreach (ref it; v.items)
            keyOf(b, it);
        break;
    }
}

// ---------------------------------------------------------------- functions

private Value fnReplace(Vfs, Value[] a)
{
    if (a[1].s.length == 0)
        throw argError("fn", "replace", "empty pattern");
    return S(replaceAll(a[0].s, a[1].s, a[2].s));
}

private Value fnSubstr(Vfs, Value[] a)
{
    size_t s, c;
    clampRange(a[0].s.length, a[1].num, a[2].num, s, c);
    return S(a[0].s[s .. s + c]);
}

private Value fnSplit(Vfs, Value[] a)
{
    auto str = a[0].s;
    auto sep = a[1].s;
    if (sep.length == 0)
        throw argError("fn", "split", "empty separator");
    Value[] r;
    size_t pos = 0;
    while (true)
    {
        auto idx = findBytes(str, sep, pos);
        if (idx == size_t.max)
            break;
        r ~= S(str[pos .. idx]);
        pos = idx + sep.length;
    }
    r ~= S(str[pos .. $]);
    return L(r);
}

private Value fnJoin(Vfs, Value[] a)
{
    Buf b;
    foreach (i, ref it; a[0].items)
    {
        if (it.kind != VKind.str && it.kind != VKind.integer)
            throw typeError("fn join element " ~ intText(i), "str|int", typeName(it.kind));
        if (i > 0)
            b.put(a[1].s);
        putInterpolated(b, it);
    }
    return S(b.take());
}

private Value fnInt(Vfs, Value[] a)
{
    if (a[0].isInt)
        return a[0];
    auto s = a[0].s;
    size_t i = 0;
    bool neg = false;
    if (s.length > 0 && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i >= s.length)
        throw argError("fn", "int", "bad integer");
    ulong v = 0;
    immutable limit = neg ? (1UL << 63) : (1UL << 63) - 1;
    for (; i < s.length; ++i)
    {
        immutable c = s[i];
        if (c < '0' || c > '9')
            throw argError("fn", "int", "bad integer");
        immutable d = c - '0';
        if (v > (limit - d) / 10)
            throw argError("fn", "int", "bad integer");
        v = v * 10 + d;
    }
    return I(neg ? cast(long)(0 - v) : cast(long) v);
}

private Value fnPathjoin(Vfs, Value[] a)
{
    Buf b;
    bool first = true;
    foreach (ref x; a)
    {
        if (x.s.length == 0)
            continue;
        if (!first)
            b.putc('/');
        b.put(x.s);
        first = false;
    }
    return S(b.take());
}

private Value fnMap(Vfs, Value[] a)
{
    auto pat = a[1].s;
    Value[] r;
    r.reserve(a[0].items.length);
    foreach (i, ref it; a[0].items)
    {
        if (!it.isStr)
            throw typeError("fn map element " ~ intText(i), "str", typeName(it.kind));
        Buf b;
        size_t k = 0;
        while (k < pat.length)
        {
            if (pat[k] == '%')
            {
                if (k + 1 < pat.length && pat[k + 1] == '%')
                {
                    b.putc('%');
                    k += 2;
                }
                else
                {
                    b.put(it.s);
                    ++k;
                }
            }
            else
                b.putc(pat[k++]);
        }
        r ~= S(b.take());
    }
    return L(r);
}

private Value filterImpl(string name, Value[] a, bool keepMatches)
{
    GlobPattern pat;
    if (!compileGlob(a[1].s, pat))
        throw argError("fn", name, "bad pattern");
    Value[] r;
    foreach (i, ref it; a[0].items)
    {
        if (!it.isStr)
            throw typeError("fn " ~ name ~ " element " ~ intText(i), "str", typeName(it.kind));
        if (globMatches(pat, it.s) == keepMatches)
            r ~= it;
    }
    return L(r);
}

private Value fnFilter(Vfs, Value[] a) { return filterImpl("filter", a, true); }
private Value fnReject(Vfs, Value[] a) { return filterImpl("reject", a, false); }

private Value fnSort(Vfs, Value[] a)
{
    auto items = a[0].items.dup;
    items.sort!((x, y) => compareValues(x, y) < 0);
    return L(items);
}

private Value fnUniq(Vfs, Value[] a)
{
    bool[string] seen;
    Value[] r;
    foreach (ref it; a[0].items)
    {
        Buf b;
        keyOf(b, it);
        auto k = b.take();
        if (k in seen)
            continue;
        seen[k] = true;
        r ~= it;
    }
    return L(r);
}

private Value fnReverse(Vfs, Value[] a)
{
    auto n = a[0].items.length;
    auto r = new Value[n];
    foreach (i; 0 .. n)
        r[i] = a[0].items[n - 1 - i];
    return L(r);
}

private Value fnFirst(Vfs, Value[] a)
{
    if (a[0].items.length == 0)
        throw argError("fn", "first", "empty list");
    return a[0].items[0];
}

private Value fnLast(Vfs, Value[] a)
{
    if (a[0].items.length == 0)
        throw argError("fn", "last", "empty list");
    return a[0].items[$ - 1];
}

private Value fnSlice(Vfs, Value[] a)
{
    size_t s, c;
    clampRange(a[0].items.length, a[1].num, a[2].num, s, c);
    return L(a[0].items[s .. s + c]);
}

private Value fnRange(Vfs, Value[] a)
{
    if (a[0].num < 0)
        throw argError("fn", "range", "negative");
    auto r = new Value[cast(size_t) a[0].num];
    foreach (i; 0 .. r.length)
        r[i] = I(cast(long) i);
    return L(r);
}

private Value fnSum(Vfs, Value[] a)
{
    ulong total = 0;
    foreach (i, ref it; a[0].items)
    {
        if (!it.isInt)
            throw typeError("fn sum element " ~ intText(i), "int", typeName(it.kind));
        total += cast(ulong) it.num;
    }
    return I(cast(long) total);
}

private Value fnFlatten(Vfs, Value[] a)
{
    Value[] r;
    foreach (ref it; a[0].items)
    {
        if (it.isList)
            r ~= it.items;
        else
            r ~= it;
    }
    return L(r);
}

private Value fnZip(Vfs, Value[] a)
{
    auto n = a[0].items.length < a[1].items.length ? a[0].items.length : a[1].items.length;
    auto r = new Value[n];
    foreach (i; 0 .. n)
        r[i] = L([a[0].items[i], a[1].items[i]]);
    return L(r);
}

private Value fnGlob(Vfs vfs, Value[] a)
{
    GlobPattern pat;
    if (!compileGlob(a[0].s, pat))
        throw argError("fn", "glob", "bad pattern");
    Value[] r;
    foreach (p; vfs.eligibleWithPrefix(pat.literalPrefix()))
        if (globMatches(pat, p))
            r ~= S(p);
    return L(r);
}

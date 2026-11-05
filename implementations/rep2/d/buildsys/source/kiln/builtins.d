/**
 * The 39 KBL built-in functions.
 *
 * `builtinId` resolves a name once (at parse time); `checkCall` applies the
 * arity and argument-type rules; `callBuiltin` runs the function.
 */
module kiln.builtins;

import kiln.errors;
import kiln.glob;
import kiln.text;
import kiln.value;
import kiln.vfs;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;

/// The built-in functions, in table order.
enum Fn : int
{
    len, count, upper, lower, trim, replace, starts_with, ends_with, contains, substr,
    split, join, str, int_, dirname, basename, stem, ext, pathjoin, map,
    filter, reject, sort_, uniq, reverse, first, last, slice, has, indexof,
    range, sum, flatten, zip, is_str, is_int, is_bool, is_list, glob,
}

/// Static description of a built-in: name, argument type codes and arity.
struct BuiltinInfo
{
    string name;
    /// One code per argument: S=str I=int L=list V=any M=str|list X=str|int|bool Y=str|int.
    string sig;
    int minArgs;
    int maxArgs;
}

/// The function table, indexed by `Fn`.
immutable BuiltinInfo[] builtinTable = [
    BuiltinInfo("len", "M", 1, 1), BuiltinInfo("count", "L", 1, 1),
    BuiltinInfo("upper", "S", 1, 1), BuiltinInfo("lower", "S", 1, 1),
    BuiltinInfo("trim", "S", 1, 1), BuiltinInfo("replace", "SSS", 3, 3),
    BuiltinInfo("starts_with", "SS", 2, 2), BuiltinInfo("ends_with", "SS", 2, 2),
    BuiltinInfo("contains", "SS", 2, 2), BuiltinInfo("substr", "SII", 3, 3),
    BuiltinInfo("split", "SS", 2, 2), BuiltinInfo("join", "LS", 2, 2),
    BuiltinInfo("str", "X", 1, 1), BuiltinInfo("int", "Y", 1, 1),
    BuiltinInfo("dirname", "S", 1, 1), BuiltinInfo("basename", "S", 1, 1),
    BuiltinInfo("stem", "S", 1, 1), BuiltinInfo("ext", "S", 1, 1),
    BuiltinInfo("pathjoin", "SSSSSSSS", 1, 8), BuiltinInfo("map", "LS", 2, 2),
    BuiltinInfo("filter", "LS", 2, 2), BuiltinInfo("reject", "LS", 2, 2),
    BuiltinInfo("sort", "L", 1, 1), BuiltinInfo("uniq", "L", 1, 1),
    BuiltinInfo("reverse", "L", 1, 1), BuiltinInfo("first", "L", 1, 1),
    BuiltinInfo("last", "L", 1, 1), BuiltinInfo("slice", "LII", 3, 3),
    BuiltinInfo("has", "LV", 2, 2), BuiltinInfo("indexof", "LV", 2, 2),
    BuiltinInfo("range", "I", 1, 1), BuiltinInfo("sum", "L", 1, 1),
    BuiltinInfo("flatten", "L", 1, 1), BuiltinInfo("zip", "LL", 2, 2),
    BuiltinInfo("is_str", "V", 1, 1), BuiltinInfo("is_int", "V", 1, 1),
    BuiltinInfo("is_bool", "V", 1, 1), BuiltinInfo("is_list", "V", 1, 1),
    BuiltinInfo("glob", "S", 1, 1),
];

static assert(builtinTable.length == 39);

private immutable int[string] ids = () {
    int[string] r;
    foreach (i, b; builtinTable)
        r[b.name] = cast(int) i;
    return r;
}();

/// The id of the built-in named `name`, or -1 if there is none.
int builtinId(string name)
{
    if (auto p = name in ids)
        return *p;
    return -1;
}

private string expectedToken(char code) @safe pure nothrow @nogc
{
    switch (code)
    {
    case 'S':
        return "str";
    case 'I':
        return "int";
    case 'L':
        return "list";
    case 'M':
        return "str|list";
    case 'X':
        return "str|int|bool";
    case 'Y':
        return "str|int";
    default:
        return "";
    }
}

private bool codeAccepts(char code, VType t) @safe pure nothrow @nogc
{
    switch (code)
    {
    case 'S':
        return t == VType.str;
    case 'I':
        return t == VType.int_;
    case 'L':
        return t == VType.list;
    case 'M':
        return t == VType.str || t == VType.list;
    case 'X':
        return t != VType.list;
    case 'Y':
        return t == VType.str || t == VType.int_;
    default:
        return true;
    }
}

/// Applies the arity check and then the argument type checks of function `id`.
void checkCall(int id, const(Value)[] args) @safe pure
{
    immutable info = &builtinTable[id];
    if (args.length < info.minArgs || args.length > info.maxArgs)
    {
        string exp = info.minArgs == info.maxArgs ? info.minArgs.to!string
            : info.minArgs.to!string ~ "-" ~ info.maxArgs.to!string;
        throw arityError("fn", info.name, exp, args.length);
    }
    foreach (i, ref a; args)
    {
        immutable code = info.sig[i];
        if (!codeAccepts(code, a.type))
            throw typeError("fn " ~ info.name ~ " argument " ~ (i + 1).to!string,
                    expectedToken(code), typeName(a.type));
    }
}

private string basenameOf(string p) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; p)
        if (c == '/')
            return p[i + 1 .. $];
    return p;
}

// Index of the last '.' of b that is not at index 0, or -1.
private ptrdiff_t extDot(string b) @safe pure nothrow @nogc
{
    foreach_reverse (i; 1 .. b.length)
        if (b[i] == '.')
            return cast(ptrdiff_t) i;
    return -1;
}

private bool parseInt64(string s, out long result) @safe pure nothrow @nogc
{
    size_t i = 0;
    bool neg = false;
    if (s.length > 0 && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i >= s.length)
        return false;
    ulong acc = 0;
    immutable ulong limit = neg ? (1UL << 63) : (1UL << 63) - 1;
    for (; i < s.length; i++)
    {
        immutable c = s[i];
        if (c < '0' || c > '9')
            return false;
        immutable d = c - '0';
        if (acc > (limit - d) / 10)
            return false;
        acc = acc * 10 + d;
    }
    result = neg ? cast(long)(0 - acc) : cast(long) acc;
    return true;
}

private Value clampWindow(size_t n, long start, long count, out size_t s, out size_t c) @safe pure nothrow @nogc
{
    if (start < 0)
        start += cast(long) n;
    if (start < 0)
        start = 0;
    if (start > cast(long) n)
        start = cast(long) n;
    if (count < 0)
        count = 0;
    if (count > cast(long) n - start)
        count = cast(long) n - start;
    s = cast(size_t) start;
    c = cast(size_t) count;
    return Value.init;
}

private GlobPattern compileOrThrow(string fnName, string pat)
{
    auto g = GlobPattern.compile(pat);
    if (g is null)
        throw argError("fn", fnName, "bad pattern");
    return g;
}

/**
 * Runs built-in `id`. The call must already have passed `checkCall`.
 * `vfs` is consulted by `glob` only.
 */
Value callBuiltin(int id, Value[] a, Vfs vfs)
{
    final switch (cast(Fn) id)
    {
    case Fn.len:
        return Value.ofInt(a[0].type == VType.str ? a[0].s.length : a[0].l.length);
    case Fn.count:
        return Value.ofInt(a[0].l.length);
    case Fn.upper:
    {
        auto b = a[0].s.dup;
        foreach (ref c; b)
            if (c >= 'a' && c <= 'z')
                c -= 32;
        return Value.ofStr(toImmutable(b));
    }
    case Fn.lower:
    {
        auto b = a[0].s.dup;
        foreach (ref c; b)
            if (c >= 'A' && c <= 'Z')
                c += 32;
        return Value.ofStr(toImmutable(b));
    }
    case Fn.trim:
    {
        string s = a[0].s;
        size_t lo = 0, hi = s.length;
        bool ws(char c)
        {
            return c == ' ' || c == '\t' || c == '\n' || c == '\r';
        }

        while (lo < hi && ws(s[lo]))
            lo++;
        while (hi > lo && ws(s[hi - 1]))
            hi--;
        return Value.ofStr(s[lo .. hi]);
    }
    case Fn.replace:
        if (a[1].s.length == 0)
            throw argError("fn", "replace", "empty pattern");
        return Value.ofStr(replaceAll(a[0].s, a[1].s, a[2].s));
    case Fn.starts_with:
        return Value.ofBool(startsWithBytes(a[0].s, a[1].s));
    case Fn.ends_with:
        return Value.ofBool(endsWithBytes(a[0].s, a[1].s));
    case Fn.contains:
        return Value.ofBool(containsBytes(a[0].s, a[1].s));
    case Fn.substr:
    {
        size_t s, c;
        clampWindow(a[0].s.length, a[1].i, a[2].i, s, c);
        return Value.ofStr(a[0].s[s .. s + c]);
    }
    case Fn.split:
    {
        string str = a[0].s, sep = a[1].s;
        if (sep.length == 0)
            throw argError("fn", "split", "empty separator");
        Value[] r;
        size_t cur = 0;
        for (;;)
        {
            immutable pos = findBytes(str, sep, cur);
            if (pos < 0)
                break;
            r ~= Value.ofStr(str[cur .. pos]);
            cur = pos + sep.length;
        }
        r ~= Value.ofStr(str[cur .. $]);
        return Value.ofList(r);
    }
    case Fn.join:
    {
        auto app = appender!(char[]);
        foreach (i, ref e; a[0].l)
        {
            if (e.type != VType.str && e.type != VType.int_)
                throw typeError("fn join element " ~ i.to!string, "str|int", typeName(e.type));
            if (i > 0)
                app.put(a[1].s);
            app.put(interpolate(e));
        }
        return Value.ofStr(toImmutable(app.data));
    }
    case Fn.str:
        return Value.ofStr(interpolate(a[0]));
    case Fn.int_:
    {
        if (a[0].type == VType.int_)
            return a[0];
        long n;
        if (!parseInt64(a[0].s, n))
            throw argError("fn", "int", "bad integer");
        return Value.ofInt(n);
    }
    case Fn.dirname:
    {
        string s = a[0].s;
        foreach_reverse (i, c; s)
            if (c == '/')
                return Value.ofStr(s[0 .. i]);
        return Value.ofStr("");
    }
    case Fn.basename:
        return Value.ofStr(basenameOf(a[0].s));
    case Fn.stem:
    {
        string b = basenameOf(a[0].s);
        immutable d = extDot(b);
        return Value.ofStr(d < 0 ? b : b[0 .. d]);
    }
    case Fn.ext:
    {
        string b = basenameOf(a[0].s);
        immutable d = extDot(b);
        return Value.ofStr(d < 0 ? "" : b[d .. $]);
    }
    case Fn.pathjoin:
    {
        auto app = appender!(char[]);
        bool any = false;
        foreach (ref e; a)
        {
            if (e.s.length == 0)
                continue;
            if (any)
                app.put('/');
            app.put(e.s);
            any = true;
        }
        return Value.ofStr(toImmutable(app.data));
    }
    case Fn.map:
    {
        string pat = a[1].s;
        auto r = new Value[a[0].l.length];
        foreach (i, ref e; a[0].l)
        {
            if (e.type != VType.str)
                throw typeError("fn map element " ~ i.to!string, "str", typeName(e.type));
            auto app = appender!(char[]);
            for (size_t k = 0; k < pat.length; k++)
            {
                if (pat[k] == '%')
                {
                    if (k + 1 < pat.length && pat[k + 1] == '%')
                    {
                        app.put('%');
                        k++;
                    }
                    else
                        app.put(e.s);
                }
                else
                    app.put(pat[k]);
            }
            r[i] = Value.ofStr(toImmutable(app.data));
        }
        return Value.ofList(r);
    }
    case Fn.filter:
    case Fn.reject:
    {
        immutable keepMatching = cast(Fn) id == Fn.filter;
        immutable name = keepMatching ? "filter" : "reject";
        auto g = compileOrThrow(name, a[1].s);
        Value[] r;
        foreach (i, ref e; a[0].l)
        {
            if (e.type != VType.str)
                throw typeError("fn " ~ name ~ " element " ~ i.to!string, "str", typeName(e.type));
            if (g.matches(e.s) == keepMatching)
                r ~= e;
        }
        return Value.ofList(r);
    }
    case Fn.sort_:
    {
        auto r = a[0].l.dup;
        r.sort!((x, y) => compareValues(x, y) < 0);
        return Value.ofList(r);
    }
    case Fn.uniq:
    {
        Value[] r;
        bool allStr = true;
        foreach (ref e; a[0].l)
            if (e.type != VType.str)
            {
                allStr = false;
                break;
            }
        if (allStr)
        {
            bool[string] seen;
            foreach (ref e; a[0].l)
                if (e.s !in seen)
                {
                    seen[e.s] = true;
                    r ~= e;
                }
        }
        else
        {
            foreach (ref e; a[0].l)
            {
                bool dup = false;
                foreach (ref x; r)
                    if (valuesEqual(x, e))
                    {
                        dup = true;
                        break;
                    }
                if (!dup)
                    r ~= e;
            }
        }
        return Value.ofList(r);
    }
    case Fn.reverse:
    {
        auto r = new Value[a[0].l.length];
        foreach (i, ref e; a[0].l)
            r[$ - 1 - i] = e;
        return Value.ofList(r);
    }
    case Fn.first:
        if (a[0].l.length == 0)
            throw argError("fn", "first", "empty list");
        return a[0].l[0];
    case Fn.last:
        if (a[0].l.length == 0)
            throw argError("fn", "last", "empty list");
        return a[0].l[$ - 1];
    case Fn.slice:
    {
        size_t s, c;
        clampWindow(a[0].l.length, a[1].i, a[2].i, s, c);
        return Value.ofList(a[0].l[s .. s + c]);
    }
    case Fn.has:
        foreach (ref e; a[0].l)
            if (valuesEqual(e, a[1]))
                return Value.ofBool(true);
        return Value.ofBool(false);
    case Fn.indexof:
        foreach (i, ref e; a[0].l)
            if (valuesEqual(e, a[1]))
                return Value.ofInt(cast(long) i);
        return Value.ofInt(-1);
    case Fn.range:
    {
        if (a[0].i < 0)
            throw argError("fn", "range", "negative");
        auto r = new Value[cast(size_t) a[0].i];
        foreach (i; 0 .. r.length)
            r[i] = Value.ofInt(cast(long) i);
        return Value.ofList(r);
    }
    case Fn.sum:
    {
        long t = 0;
        foreach (i, ref e; a[0].l)
        {
            if (e.type != VType.int_)
                throw typeError("fn sum element " ~ i.to!string, "int", typeName(e.type));
            t += e.i;
        }
        return Value.ofInt(t);
    }
    case Fn.flatten:
    {
        Value[] r;
        foreach (ref e; a[0].l)
            if (e.type == VType.list)
                r ~= e.l;
            else
                r ~= e;
        return Value.ofList(r);
    }
    case Fn.zip:
    {
        immutable n = a[0].l.length < a[1].l.length ? a[0].l.length : a[1].l.length;
        auto r = new Value[n];
        foreach (i; 0 .. n)
            r[i] = Value.ofList([a[0].l[i], a[1].l[i]]);
        return Value.ofList(r);
    }
    case Fn.is_str:
        return Value.ofBool(a[0].type == VType.str);
    case Fn.is_int:
        return Value.ofBool(a[0].type == VType.int_);
    case Fn.is_bool:
        return Value.ofBool(a[0].type == VType.bool_);
    case Fn.is_list:
        return Value.ofBool(a[0].type == VType.list);
    case Fn.glob:
    {
        auto g = compileOrThrow("glob", a[0].s);
        Value[] r;
        foreach (p; vfs.globRange(g.literalPrefix))
            if (g.matches(p))
                r ~= Value.ofStr(p);
        return Value.ofList(r);
    }
    }
}

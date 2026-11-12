/**
 * The thirteen template filters.
 */
module sitegen.templating.filters;

import std.array : Appender, appender;
import sitegen.templating.errors;
import sitegen.templating.value;

/// Whether `name` is the name of a filter.
bool isFilterName(string name) pure nothrow @nogc @safe
{
    switch (name)
    {
        case "upper", "lower", "trim", "escape", "replace", "length", "int", "join", "first",
            "last", "reverse", "sort", "default":
            return true;
        default:
            return false;
    }
}

private bool isWs(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

private void expectArgs(const Value[] args, size_t lo, size_t hi)
{
    if (args.length < lo || args.length > hi) typeError("wrong number of filter arguments");
}

/**
 * Applies the filter `name` to `input`.
 *
 * The caller has already evaluated the input and the arguments.  Except for
 * `default`, an undefined input is an `undefined` error, which is checked
 * before the number of arguments.
 */
Value applyFilter(string name, Value input, Value[] args)
{
    if (name == "default")
    {
        expectArgs(args, 0, 1);
        if (!input.isUndefined) return input;
        return args.length ? args[0] : Value.str("");
    }
    if (input.isUndefined) undefinedError("filter applied to the undefined value");
    switch (name)
    {
        case "upper":
            expectArgs(args, 0, 0);
            return Value.str(mapAscii(toDisplay(input), true));
        case "lower":
            expectArgs(args, 0, 0);
            return Value.str(mapAscii(toDisplay(input), false));
        case "trim":
            expectArgs(args, 0, 0);
            return Value.str(trimWs(toDisplay(input)));
        case "escape":
            expectArgs(args, 0, 0);
            return Value.str(escapeHtml(toDisplay(input)));
        case "replace":
            expectArgs(args, 2, 2);
            return Value.str(replaceAll(toDisplay(input), toDisplay(args[0]), toDisplay(args[1])));
        case "length":
            expectArgs(args, 0, 0);
            switch (input.kind)
            {
                case Kind.string_: return Value.integer(cast(long) codePointCount(input.s));
                case Kind.list: return Value.integer(cast(long) input.l.length);
                case Kind.dict: return Value.integer(cast(long) input.d.length);
                default: typeError("length of a value without length");
            }
        case "int":
            expectArgs(args, 0, 0);
            return Value.integer(toInt(input));
        case "join":
            {
                expectArgs(args, 0, 1);
                auto seq = sequenceOf(input);
                const sep = args.length ? toDisplay(args[0]) : "";
                auto o = appender!string();
                foreach (idx, e; seq)
                {
                    if (idx) o.put(sep);
                    appendDisplay(o, e);
                }
                return Value.str(o.data);
            }
        case "first":
            {
                expectArgs(args, 0, 0);
                auto seq = sequenceOf(input);
                return seq.length ? seq[0] : Value.undefined;
            }
        case "last":
            {
                expectArgs(args, 0, 0);
                auto seq = sequenceOf(input);
                return seq.length ? seq[$ - 1] : Value.undefined;
            }
        case "reverse":
            {
                expectArgs(args, 0, 0);
                if (input.kind == Kind.string_)
                {
                    auto chars = sequenceOf(input);
                    auto o = appender!string();
                    foreach_reverse (c; chars) o.put(c.s);
                    return Value.str(o.data);
                }
                auto seq = sequenceOf(input);
                auto r = new Value[seq.length];
                foreach (idx, e; seq) r[$ - 1 - idx] = e;
                return Value.list(r);
            }
        case "sort":
            expectArgs(args, 0, 0);
            return sortValues(sequenceOf(input));
        default:
            assert(0, "unknown filter " ~ name);
    }
}

private string mapAscii(string s, bool upper) pure
{
    char[] r = s.dup;
    foreach (ref c; r)
    {
        if (upper && c >= 'a' && c <= 'z')
            c -= 32;
        else if (!upper && c >= 'A' && c <= 'Z')
            c += 32;
    }
    return cast(string) r;
}

private string trimWs(string s) pure nothrow @nogc @safe
{
    size_t a = 0, b = s.length;
    while (a < b && isWs(s[a])) a++;
    while (b > a && isWs(s[b - 1])) b--;
    return s[a .. b];
}

private string escapeHtml(string s) pure
{
    auto o = appender!string();
    foreach (char c; s)
    {
        switch (c)
        {
            case '&': o.put("&amp;"); break;
            case '<': o.put("&lt;"); break;
            case '>': o.put("&gt;"); break;
            case '"': o.put("&#34;"); break;
            case '\'': o.put("&#39;"); break;
            default: o.put(c);
        }
    }
    return o.data;
}

private string replaceAll(string s, string from, string to) pure
{
    import std.string : indexOf;

    if (from.length == 0) return s;
    auto o = appender!string();
    size_t i = 0;
    while (true)
    {
        const j = s[i .. $].indexOf(from);
        if (j < 0) break;
        o.put(s[i .. i + j]);
        o.put(to);
        i += j + from.length;
    }
    o.put(s[i .. $]);
    return o.data;
}

private long toInt(const Value v)
{
    import std.math : trunc;

    switch (v.kind)
    {
        case Kind.integer, Kind.boolean:
            return v.i;
        case Kind.floating:
            return cast(long) trunc(v.f);
        case Kind.string_:
            return parseIntString(v.s);
        default:
            return 0;
    }
}

private long parseIntString(string raw)
{
    import std.math : trunc;

    const s = trimWs(raw);
    size_t i = 0;
    bool neg = false;
    if (i < s.length && (s[i] == '+' || s[i] == '-'))
    {
        neg = s[i] == '-';
        i++;
    }
    const intStart = i;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') i++;
    const intDigits = s[intStart .. i];
    if (intDigits.length && i == s.length)
    {
        long v = 0;
        foreach (c; intDigits) v = v * 10 + (c - '0');
        return neg ? -v : v;
    }
    // Decimal form: digits [. digits] [e[+-]digits] or . digits [...]
    string fracDigits;
    if (i < s.length && s[i] == '.')
    {
        i++;
        const fs = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9') i++;
        fracDigits = s[fs .. i];
    }
    else if (intDigits.length == 0)
        return 0;
    if (intDigits.length == 0 && fracDigits.length == 0) return 0;
    string expPart;
    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        size_t k = i + 1;
        if (k < s.length && (s[k] == '+' || s[k] == '-')) k++;
        const ds = k;
        while (k < s.length && s[k] >= '0' && s[k] <= '9') k++;
        if (k == ds) return 0;
        expPart = s[i .. k];
        i = k;
    }
    if (i != s.length) return 0;
    const text = (neg ? "-" : "") ~ (intDigits.length ? intDigits : "0") ~ "."
        ~ (fracDigits.length ? fracDigits : "0") ~ expPart;
    return cast(long) trunc(parseDouble(text));
}

private Value sortValues(Value[] seq)
{
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;

    auto items = seq.dup;
    if (items.length < 2) return Value.list(items);
    bool allNumbers = true, allStrings = true;
    foreach (ref e; items)
    {
        if (!e.isNumber) allNumbers = false;
        if (e.kind != Kind.string_) allStrings = false;
    }
    if (allNumbers)
    {
        bool allIntegral = true;
        foreach (ref e; items)
            if (!e.isIntegral) allIntegral = false;
        if (allIntegral)
            items.sort!((a, b) => a.i < b.i, SwapStrategy.stable);
        else
            items.sort!((a, b) => a.asDouble < b.asDouble, SwapStrategy.stable);
    }
    else if (allStrings)
    {
        static struct Keyed
        {
            string key;
            Value v;
        }

        auto keyed = new Keyed[items.length];
        foreach (idx, ref e; items) keyed[idx] = Keyed(mapAscii(e.s, false), e);
        keyed.sort!((a, b) => a.key < b.key, SwapStrategy.stable);
        foreach (idx, ref k; keyed) items[idx] = k.v;
    }
    else
        typeError("cannot sort a mixture of kinds");
    return Value.list(items);
}

unittest
{
    alias S = Value.str;
    alias I = Value.integer;
    assert(applyFilter("upper", S("aBc"), []).s == "ABC");
    assert(applyFilter("lower", S("aBc"), []).s == "abc");
    assert(applyFilter("trim", S(" \t x y \n"), []).s == "x y");
    assert(applyFilter("escape", S(`<a href="x">'&'</a>`), []).s
            == "&lt;a href=&#34;x&#34;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    assert(applyFilter("replace", S("a-b-c"), [S("-"), S("+")]).s == "a+b+c");
    assert(applyFilter("length", S("aé"), []).i == 2);
    assert(applyFilter("int", S(" 42 "), []).i == 42);
    assert(applyFilter("int", S("-3.9"), []).i == -3);
    assert(applyFilter("int", S("abc"), []).i == 0);
    assert(applyFilter("int", S("1e3"), []).i == 1000);
    assert(applyFilter("int", Value.floating(-2.7), []).i == -2);
    assert(applyFilter("join", Value.list([I(1), S("b")]), [S("-")]).s == "1-b");
    assert(applyFilter("first", S("xyz"), []).s == "x");
    assert(applyFilter("last", Value.list([I(1), I(2)]), []).i == 2);
    assert(applyFilter("first", Value.list(cast(Value[])[]), []).isUndefined);
    assert(applyFilter("reverse", S("abc"), []).s == "cba");
    assert(applyFilter("sort", Value.list([S("b"), S("A"), S("a")]), []).l[0].s == "A");
    assert(applyFilter("sort", Value.list([I(3), I(1), I(2)]), []).l[0].i == 1);
    assert(applyFilter("default", Value.undefined, [S("d")]).s == "d");
    assert(applyFilter("default", S("x"), [S("d")]).s == "x");
}

/// The built-in filters.
module jinjalite.filters;

import core.stdc.stdlib : strtod;
import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;
import std.array : appender, replace;
import jinjalite.errors;
import jinjalite.lexer : isWhitespace;
import jinjalite.operators : sequenceView;
import jinjalite.value;

/// Identifies a built-in filter.
enum FilterId : ubyte
{
    upper, lower, trim, escape, replace, length, int_, join, first, last, reverse, sort, default_,
    /// Not a filter; reported as a `filter` error when the template is loaded.
    unknown,
}

/// Resolve a filter name, or `FilterId.unknown`.
FilterId lookupFilter(string name) pure nothrow @safe @nogc
{
    switch (name)
    {
    case "upper":   return FilterId.upper;
    case "lower":   return FilterId.lower;
    case "trim":    return FilterId.trim;
    case "escape":  return FilterId.escape;
    case "replace": return FilterId.replace;
    case "length":  return FilterId.length;
    case "int":     return FilterId.int_;
    case "join":    return FilterId.join;
    case "first":   return FilterId.first;
    case "last":    return FilterId.last;
    case "reverse": return FilterId.reverse;
    case "sort":    return FilterId.sort;
    case "default": return FilterId.default_;
    default:        return FilterId.unknown;
    }
}

private struct Arity { ubyte min, max; }

private Arity arityOf(FilterId id) pure nothrow @safe @nogc
{
    switch (id)
    {
    case FilterId.replace:  return Arity(2, 2);
    case FilterId.join:
    case FilterId.default_: return Arity(0, 1);
    default:                return Arity(0, 0);
    }
}

/++
    Apply filter `id` to `input` with already evaluated `args`.

    Except for `default`, an undefined input is an `undefined` error; only then
    is the argument count checked (a `type` error).
+/
Value applyFilter(FilterId id, Value input, Value[] args)
{
    if (id != FilterId.default_)
        requireDefined(input, "filter applied to an undefined value");
    const arity = arityOf(id);
    if (args.length < arity.min || args.length > arity.max)
        typeError("wrong number of arguments for filter");

    final switch (id)
    {
    case FilterId.upper:
        return Value.text(mapAscii(toStr(input), true));
    case FilterId.lower:
        return Value.text(mapAscii(toStr(input), false));
    case FilterId.trim:
        return Value.text(trim(toStr(input)));
    case FilterId.escape:
        return Value.text(escapeHtml(toStr(input)));
    case FilterId.replace:
        return Value.text(toStr(input).replace(toStr(args[0]), toStr(args[1])));
    case FilterId.length:
        switch (input.kind)
        {
        case Kind.text: return Value.integer(cast(long) codePointCount(input.s));
        case Kind.list: return Value.integer(cast(long) input.items.length);
        case Kind.dict: return Value.integer(cast(long) input.asDict.length);
        default: typeError("object has no length");
        }
    case FilterId.int_:
        return Value.integer(toInteger(input));
    case FilterId.join:
    {
        auto seq = sequenceView(input);
        string sep = args.length ? toStr(args[0]) : "";
        auto sink = appender!(char[])();
        foreach (idx, item; seq)
        {
            if (idx)
                sink.put(sep);
            putValue(sink, item);
        }
        return Value.text(cast(string) sink.data);
    }
    case FilterId.first:
        return firstOrLast(input, true);
    case FilterId.last:
        return firstOrLast(input, false);
    case FilterId.reverse:
        return reverse(input);
    case FilterId.sort:
        return sortValues(input);
    case FilterId.default_:
        if (input.isUndefined)
            return args.length ? args[0] : Value.text("");
        return input;
    case FilterId.unknown:
        throw new TemplateError(ErrorKind.filter, "unknown filter");
    }
}

private string mapAscii(string s, bool toUpper)
{
    const from = toUpper ? 'a' : 'A';
    const to = toUpper ? 'z' : 'Z';
    const delta = toUpper ? cast(char)('A' - 'a') : cast(char)('a' - 'A');
    size_t firstChange = s.length;
    foreach (idx, c; s)
        if (c >= from && c <= to)
        {
            firstChange = idx;
            break;
        }
    if (firstChange == s.length)
        return s;
    auto result = s.dup;
    foreach (ref c; result[firstChange .. $])
        if (c >= from && c <= to)
            c = cast(char)(c + delta);
    return cast(string) result;
}

private string trim(string s) pure nothrow @safe @nogc
{
    size_t a = 0, b = s.length;
    while (a < b && isWhitespace(s[a]))
        ++a;
    while (b > a && isWhitespace(s[b - 1]))
        --b;
    return s[a .. b];
}

private string escapeHtml(string s)
{
    size_t start = 0;
    auto sink = appender!(char[])();
    foreach (idx, c; s)
    {
        string rep;
        switch (c)
        {
        case '&':  rep = "&amp;"; break;
        case '<':  rep = "&lt;"; break;
        case '>':  rep = "&gt;"; break;
        case '"':  rep = "&#34;"; break;
        case '\'': rep = "&#39;"; break;
        default: break;
        }
        if (rep.length)
        {
            sink.put(s[start .. idx]);
            sink.put(rep);
            start = idx + 1;
        }
    }
    if (start == 0)
        return s;
    sink.put(s[start .. $]);
    return cast(string) sink.data;
}

private long toInteger(Value v)
{
    switch (v.kind)
    {
    case Kind.integer:
    case Kind.boolean:
        return v.i;
    case Kind.floating:
        return cast(long) v.d;
    case Kind.text:
        return parseIntegerString(trim(v.s));
    default:
        return 0;
    }
}

/// The `int` filter's reading of a (trimmed) string: an integer, a decimal truncated toward zero, or 0.
private long parseIntegerString(string s)
{
    size_t p = 0;
    const n = s.length;
    if (p < n && (s[p] == '+' || s[p] == '-'))
        ++p;
    const digitsStart = p;
    while (p < n && s[p] >= '0' && s[p] <= '9')
        ++p;
    const intDigits = p - digitsStart;
    if (intDigits > 0 && p == n)
    {
        const negative = s[0] == '-';
        ulong magnitude = 0;
        foreach (c; s[digitsStart .. n])
            magnitude = magnitude * 10 + (c - '0');
        return negative ? cast(long)(-magnitude) : cast(long) magnitude;
    }
    // Decimal: digits [. digits] | . digits, then an optional exponent.
    size_t fracDigits = 0;
    if (p < n && s[p] == '.')
    {
        ++p;
        const fs = p;
        while (p < n && s[p] >= '0' && s[p] <= '9')
            ++p;
        fracDigits = p - fs;
    }
    if (intDigits == 0 && fracDigits == 0)
        return 0;
    if (p < n && (s[p] == 'e' || s[p] == 'E'))
    {
        ++p;
        if (p < n && (s[p] == '+' || s[p] == '-'))
            ++p;
        const es = p;
        while (p < n && s[p] >= '0' && s[p] <= '9')
            ++p;
        if (p == es)
            return 0;
    }
    if (p != n)
        return 0;
    auto z = s ~ '\0';
    const x = strtod(z.ptr, null);
    return cast(long) x;
}

private Value firstOrLast(Value input, bool first)
{
    if (input.kind == Kind.text)
    {
        auto s = input.s;
        if (s.length == 0)
            return Value.undefined;
        if (first)
            return Value.text(s[0 .. utf8Length(s[0])]);
        size_t end = s.length, start = end - 1;
        while (start > 0 && (s[start] & 0xC0) == 0x80)
            --start;
        return Value.text(s[start .. end]);
    }
    auto seq = sequenceView(input);
    if (seq.length == 0)
        return Value.undefined;
    return first ? seq[0] : seq[$ - 1];
}

private Value reverse(Value input)
{
    if (input.kind == Kind.text)
    {
        auto s = input.s;
        auto result = new char[s.length];
        size_t end = s.length;
        size_t pos = 0;
        while (pos < s.length)
        {
            const len = utf8Length(s[pos]);
            result[end - len .. end] = s[pos .. pos + len];
            end -= len;
            pos += len;
        }
        return Value.text(cast(string) result);
    }
    auto seq = sequenceView(input);
    auto result = new Value[seq.length];
    foreach (idx, item; seq)
        result[seq.length - 1 - idx] = item;
    return Value.list(result);
}

private string asciiLower(string s)
{
    return mapAscii(s, false);
}

private Value sortValues(Value input)
{
    auto seq = sequenceView(input);
    bool allNumbers = true, allText = true;
    foreach (item; seq)
    {
        allNumbers = allNumbers && item.isNumber;
        allText = allText && item.kind == Kind.text;
    }
    if (!allNumbers && !allText)
        typeError("sort needs all numbers or all strings");

    auto result = seq.dup;
    if (allNumbers)
    {
        result.sort!((a, b) => numberLess(a, b), SwapStrategy.stable);
        return Value.list(result);
    }
    struct Keyed { string key; Value value; }
    auto keyed = new Keyed[seq.length];
    foreach (idx, item; seq)
        keyed[idx] = Keyed(asciiLower(item.s), item);
    keyed.sort!((a, b) => compareText(a.key, b.key) < 0, SwapStrategy.stable);
    foreach (idx, ref k; keyed)
        result[idx] = k.value;
    return Value.list(result);
}

private bool numberLess(Value a, Value b) pure nothrow @safe @nogc
{
    if (a.kind != Kind.floating && b.kind != Kind.floating)
        return a.i < b.i;
    return a.asDouble < b.asDouble;
}

version (unittest)
{
    private Value T(string s) { return Value.text(s); }
    private Value I(long n) { return Value.integer(n); }
    private string run(FilterId id, Value input, Value[] args = null)
    {
        return toStr(applyFilter(id, input, args));
    }
}

unittest
{
    assert(lookupFilter("upper") == FilterId.upper);
    assert(lookupFilter("nope") == FilterId.unknown);
    assert(run(FilterId.upper, T("abC1é")) == "ABC1é");
    assert(run(FilterId.lower, T("ABc")) == "abc");
    assert(run(FilterId.trim, T(" \t\n x y \r\f\v")) == "x y");
    assert(run(FilterId.escape, T(`<a href="x">'&'</a>`)) == "&lt;a href=&#34;x&#34;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    assert(run(FilterId.replace, T("aaa"), [T("aa"), T("b")]) == "ba");
    assert(run(FilterId.length, T("héllo")) == "5");
    assert(run(FilterId.join, Value.list([I(1), T("a"), Value.none]), [T("-")]) == "1-a-None");
    assert(run(FilterId.join, T("abc")) == "abc");
    assert(run(FilterId.first, T("éa")) == "é");
    assert(run(FilterId.last, T("aé")) == "é");
    assert(applyFilter(FilterId.first, Value.list([]), null).isUndefined);
    assert(run(FilterId.reverse, T("aéb")) == "bé" ~ "a");
    assert(run(FilterId.reverse, Value.list([I(1), I(2)])) == "[2, 1]");
    assert(run(FilterId.default_, Value.undefined, [T("d")]) == "d");
    assert(run(FilterId.default_, Value.undefined) == "");
    assert(run(FilterId.default_, I(0), [T("d")]) == "0");
}

unittest
{
    assert(run(FilterId.int_, T("  42 ")) == "42");
    assert(run(FilterId.int_, T("-7")) == "-7");
    assert(run(FilterId.int_, T("3.99")) == "3");
    assert(run(FilterId.int_, T("-3.99")) == "-3");
    assert(run(FilterId.int_, T("1e3")) == "1000");
    assert(run(FilterId.int_, T(".5")) == "0");
    assert(run(FilterId.int_, T("5.")) == "5");
    assert(run(FilterId.int_, T("abc")) == "0");
    assert(run(FilterId.int_, T("1e")) == "0");
    assert(run(FilterId.int_, Value.floating(-2.7)) == "-2");
    assert(run(FilterId.int_, Value.none) == "0");
    assert(run(FilterId.int_, Value.boolean(true)) == "1");
}

unittest
{
    import std.exception : assertThrown;
    assert(run(FilterId.sort, Value.list([I(3), Value.floating(1.5), I(2)])) == "[1.5, 2, 3]");
    // Strings sort by their ASCII-lowercased form; equal keys keep their order.
    assert(run(FilterId.sort, Value.list([T("b"), T("A"), T("a"), T("B")])) == "['A', 'a', 'b', 'B']");
    assertThrown!TemplateError(applyFilter(FilterId.sort, Value.list([I(1), T("a")]), null));
    assertThrown!TemplateError(applyFilter(FilterId.upper, Value.undefined, [I(1)]));
    assertThrown!TemplateError(applyFilter(FilterId.default_, Value.undefined, [I(1), I(2)]));
    assertThrown!TemplateError(applyFilter(FilterId.length, I(1), null));
    assertThrown!TemplateError(applyFilter(FilterId.upper, I(1), [I(1)]));
}

/// The thirteen built-in template filters.
module sitegen.templating.filters;

import sitegen.templating.ast : FilterId;
import sitegen.templating.errors;
import sitegen.templating.ops;
import sitegen.templating.value;
import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy, reverse;
import std.array : appender, replace;
import std.conv : to;

private bool isWs(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

private string trimWs(string s) pure nothrow @safe @nogc
{
    size_t a = 0, b = s.length;
    while (a < b && isWs(s[a]))
        ++a;
    while (b > a && isWs(s[b - 1]))
        --b;
    return s[a .. b];
}

private string asString(Value v)
{
    if (v.isUndefined)
        throw undefinedError("undefined filter operand");
    return toDisplay(v);
}

private string asciiLower(string s)
{
    char[] r = s.dup;
    foreach (ref c; r)
        if (c >= 'A' && c <= 'Z')
            c += 32;
    return r.idup;
}

private string asciiUpper(string s)
{
    char[] r = s.dup;
    foreach (ref c; r)
        if (c >= 'a' && c <= 'z')
            c -= 32;
    return r.idup;
}

private string escapeText(string s)
{
    auto o = appender!(char[])();
    foreach (c; s)
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
    return o.data.idup;
}

private bool allDigits(string s) pure nothrow @safe @nogc
{
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (c < '0' || c > '9')
            return false;
    return true;
}

/// The `int` filter applied to a string.
private long intOfString(string raw)
{
    string s = trimWs(raw);
    string digits = s;
    if (digits.length && (digits[0] == '+' || digits[0] == '-'))
        digits = digits[1 .. $];
    if (allDigits(digits))
    {
        long v = 0;
        foreach (c; digits)
            v = v * 10 + (c - '0');
        return s[0] == '-' ? -v : v;
    }
    // decimal form: [+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?
    size_t i = 0;
    if (i < s.length && (s[i] == '+' || s[i] == '-'))
        ++i;
    size_t intStart = i;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
        ++i;
    size_t intDigits = i - intStart;
    size_t fracDigits = 0;
    if (i < s.length && s[i] == '.')
    {
        ++i;
        size_t fs = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            ++i;
        fracDigits = i - fs;
    }
    if (intDigits == 0 && fracDigits == 0)
        return 0;
    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        size_t j = i + 1;
        if (j < s.length && (s[j] == '+' || s[j] == '-'))
            ++j;
        size_t es = j;
        while (j < s.length && s[j] >= '0' && s[j] <= '9')
            ++j;
        if (j == es)
            return 0;
        i = j;
    }
    if (i != s.length)
        return 0;
    double d = parseDouble(s);
    if (d >= 9.2e18)
        return long.max;
    if (d <= -9.2e18)
        return long.min;
    return cast(long) d;
}

private void checkArgs(Value[] args, size_t lo, size_t hi)
{
    if (args.length < lo || args.length > hi)
        throw typeError("wrong number of filter arguments");
    foreach (a; args)
        if (a.isUndefined)
            throw undefinedError("undefined filter argument");
}

private Value firstOrLast(Value input, bool last)
{
    auto seq = sequenceView(input);
    if (seq.length == 0)
        return Value.undefined;
    return last ? seq[$ - 1] : seq[0];
}

/// Apply filter `id` (other than `default`) to a defined `input`.
Value applyFilter(FilterId id, Value input, Value[] args)
{
    final switch (id)
    {
    case FilterId.upper:
        checkArgs(args, 0, 0);
        return Value.of(asciiUpper(asString(input)));
    case FilterId.lower:
        checkArgs(args, 0, 0);
        return Value.of(asciiLower(asString(input)));
    case FilterId.trim:
        checkArgs(args, 0, 0);
        return Value.of(trimWs(asString(input)));
    case FilterId.escape:
        checkArgs(args, 0, 0);
        return Value.of(escapeText(asString(input)));
    case FilterId.replace:
    {
        checkArgs(args, 2, 2);
        string old = asString(args[0]);
        string rep = asString(args[1]);
        string s = asString(input);
        if (old.length == 0)
            return Value.of(s);
        return Value.of(s.replace(old, rep));
    }
    case FilterId.length:
        checkArgs(args, 0, 0);
        switch (input.kind)
        {
        case Kind.text:
            return Value.of(cast(long) countCodePoints(input.s));
        case Kind.list:
            return Value.of(cast(long) input.items.length);
        case Kind.dict:
            return Value.of(cast(long) input.dict.length);
        default:
            throw typeError("length of a non-container");
        }
    case FilterId.int_:
        checkArgs(args, 0, 0);
        switch (input.kind)
        {
        case Kind.integer:
            return input;
        case Kind.boolean:
            return Value.of(input.i);
        case Kind.floating:
            return Value.of(cast(long) input.d);
        case Kind.text:
            return Value.of(intOfString(input.s));
        default:
            return Value.of(0L);
        }
    case FilterId.join:
    {
        checkArgs(args, 0, 1);
        string sep = args.length ? asString(args[0]) : "";
        auto seq = sequenceView(input);
        auto o = appender!(char[])();
        foreach (k, e; seq)
        {
            if (k)
                o.put(sep);
            if (e.isUndefined)
                throw undefinedError("undefined in join");
            putDisplay(o, e);
        }
        return Value.of(o.data.idup);
    }
    case FilterId.first:
        checkArgs(args, 0, 0);
        return firstOrLast(input, false);
    case FilterId.last:
        checkArgs(args, 0, 0);
        return firstOrLast(input, true);
    case FilterId.reverse:
    {
        checkArgs(args, 0, 0);
        if (input.kind == Kind.text)
        {
            auto cps = codePoints(input.s);
            cps.reverse();
            auto o = appender!(char[])();
            foreach (c; cps)
                o.put(c);
            return Value.of(o.data.idup);
        }
        auto seq = sequenceView(input).dup;
        seq.reverse();
        return Value.of(seq);
    }
    case FilterId.sort:
        checkArgs(args, 0, 0);
        return sortValues(sequenceView(input).dup);
    case FilterId.default_:
    case FilterId.unknown:
        throw typeError("unexpected filter");
    }
}

private Value sortValues(Value[] seq)
{
    if (seq.length == 0)
        return Value.of(seq);
    bool allNumbers = true, allTexts = true;
    foreach (v; seq)
    {
        if (v.isUndefined)
            throw undefinedError("sorting undefined");
        if (!v.isNumber)
            allNumbers = false;
        if (v.kind != Kind.text)
            allTexts = false;
    }
    if (allNumbers)
    {
        bool anyFloat = false;
        foreach (v; seq)
            if (v.kind == Kind.floating)
                anyFloat = true;
        if (anyFloat)
            seq.sort!((a, b) => a.asDouble < b.asDouble, SwapStrategy.stable);
        else
            seq.sort!((a, b) => a.i < b.i, SwapStrategy.stable);
        return Value.of(seq);
    }
    if (allTexts)
    {
        struct Keyed
        {
            string key;
            Value value;
        }

        auto keyed = new Keyed[seq.length];
        foreach (k, v; seq)
            keyed[k] = Keyed(asciiLower(v.s), v);
        keyed.sort!((a, b) => a.key < b.key, SwapStrategy.stable);
        foreach (k, ref e; keyed)
            seq[k] = e.value;
        return Value.of(seq);
    }
    throw typeError("cannot sort mixed values");
}

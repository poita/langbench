/// The thirteen built-in filters.
module jtemplate.filters;

import core.stdc.stdlib : strtod;

import jtemplate.ast : FilterId;
import jtemplate.buffer;
import jtemplate.errors;
import jtemplate.format;
import jtemplate.lexer : isSpace;
import jtemplate.ops;
import jtemplate.value;

/// Apply filter `id` to `input` with already evaluated `args`.
///
/// The caller has evaluated the input and the arguments (in that order).
/// Here, for every filter but `default`, an undefined input is reported
/// first, then the argument count is checked, then the filter runs.
Value applyFilter(FilterId id, Value input, Value[] args)
{
    if (id == FilterId.default_)
    {
        if (args.length > 1) throw typeError("default takes at most one argument");
        if (!input.isUndefined) return input;
        return args.length ? args[0] : Value.fromString("");
    }
    if (input.isUndefined)
        throw undefinedError("filter applied to an undefined value");

    final switch (id)
    {
        case FilterId.unknown:
            throw filterError("unknown filter");
        case FilterId.default_:
            assert(0);
        case FilterId.upper:
            needArgs(args, 0, 0);
            return Value.fromString(mapAscii(toStr(input), true));
        case FilterId.lower:
            needArgs(args, 0, 0);
            return Value.fromString(mapAscii(toStr(input), false));
        case FilterId.trim:
            needArgs(args, 0, 0);
            return Value.fromString(trimSpace(toStr(input)));
        case FilterId.escape:
            needArgs(args, 0, 0);
            return Value.fromString(escapeHtml(toStr(input)));
        case FilterId.replace:
            needArgs(args, 2, 2);
            return Value.fromString(replaceAll(toStr(input), toStr(args[0]), toStr(args[1])));
        case FilterId.length:
            needArgs(args, 0, 0);
            return Value.fromInt(lengthOf(input));
        case FilterId.int_:
            needArgs(args, 0, 0);
            return Value.fromInt(toInt(input));
        case FilterId.join:
            needArgs(args, 0, 1);
            return Value.fromString(join(input, args.length ? toStr(args[0]) : ""));
        case FilterId.first:
        {
            needArgs(args, 0, 0);
            auto seq = sequenceView(input);
            return seq.length ? seq[0] : Value.undef;
        }
        case FilterId.last:
        {
            needArgs(args, 0, 0);
            auto seq = sequenceView(input);
            return seq.length ? seq[$ - 1] : Value.undef;
        }
        case FilterId.reverse:
            needArgs(args, 0, 0);
            return reverse(input);
        case FilterId.sort:
            needArgs(args, 0, 0);
            return sortValues(input);
    }
}

private void needArgs(Value[] args, size_t lo, size_t hi) pure @safe
{
    if (args.length < lo || args.length > hi)
        throw typeError("wrong number of filter arguments");
}

private string mapAscii(string s, bool upper) pure nothrow @trusted
{
    size_t first = size_t.max;
    foreach (i, c; s)
    {
        if (upper ? (c >= 'a' && c <= 'z') : (c >= 'A' && c <= 'Z'))
        {
            first = i;
            break;
        }
    }
    if (first == size_t.max) return s;
    auto buf = s.dup;
    foreach (i; first .. buf.length)
    {
        immutable c = buf[i];
        if (upper) { if (c >= 'a' && c <= 'z') buf[i] = cast(char)(c - 32); }
        else       { if (c >= 'A' && c <= 'Z') buf[i] = cast(char)(c + 32); }
    }
    return cast(string) buf;
}

/// Remove leading and trailing whitespace (the six characters).
string trimSpace(string s) pure nothrow @safe @nogc
{
    size_t a = 0, b = s.length;
    while (a < b && isSpace(s[a])) ++a;
    while (b > a && isSpace(s[b - 1])) --b;
    return s[a .. b];
}

private string escapeHtml(string s) nothrow @trusted
{
    size_t extra = 0;
    foreach (c; s)
        if (c == '&' || c == '<' || c == '>' || c == '"' || c == '\'') ++extra;
    if (extra == 0) return s;
    OutBuf b;
    b.reserve(s.length + extra * 5);
    size_t run = 0;
    foreach (i, c; s)
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
        if (rep !is null)
        {
            b.put(s[run .. i]);
            b.put(rep);
            run = i + 1;
        }
    }
    b.put(s[run .. $]);
    return b.take();
}

private string replaceAll(string s, string old, string repl) nothrow @trusted
{
    import core.stdc.string : memchr, memcmp;
    OutBuf b;
    if (old.length == 0)
    {
        // Python semantics: the replacement goes between every character.
        b.put(repl);
        size_t i = 0;
        while (i < s.length)
        {
            immutable n = utf8Stride(s[i]);
            b.put(s[i .. i + n]);
            b.put(repl);
            i += n;
        }
        return b.take();
    }
    size_t pos = 0, run = 0;
    bool any = false;
    while (pos + old.length <= s.length)
    {
        auto p = cast(const(char)*) memchr(s.ptr + pos, old[0], s.length - pos - old.length + 1);
        if (p is null) break;
        immutable at = p - s.ptr;
        if (memcmp(s.ptr + at, old.ptr, old.length) == 0)
        {
            any = true;
            b.put(s[run .. at]);
            b.put(repl);
            pos = run = at + old.length;
        }
        else
            pos = at + 1;
    }
    if (!any) return s;
    b.put(s[run .. $]);
    return b.take();
}

private long lengthOf(Value v) @trusted
{
    switch (v.kind)
    {
        case Kind.str:  return cast(long) codePointCount(v.s);
        case Kind.list: return cast(long) v.list.length;
        case Kind.dict: return cast(long) v.dict.length;
        default: throw typeError("object has no length");
    }
}

private string join(Value v, string sep)
{
    auto seq = sequenceView(v);
    OutBuf b;
    foreach (i, ref e; seq)
    {
        if (i) b.put(sep);
        putValue(b, e);
    }
    return b.take();
}

private Value reverse(Value v) @trusted
{
    if (v.kind == Kind.str)
    {
        auto s = v.s;
        auto buf = new char[s.length];
        size_t end = s.length, w = 0;
        while (end > 0)
        {
            size_t start = end - 1;
            while (start > 0 && (s[start] & 0xC0) == 0x80) --start;
            buf[w .. w + end - start] = s[start .. end];
            w += end - start;
            end = start;
        }
        return Value.fromString(cast(string) buf);
    }
    auto seq = sequenceView(v);
    auto r = new Value[seq.length];
    foreach (i, ref e; seq)
        r[$ - 1 - i] = e;
    return Value.fromList(r);
}

private Value sortValues(Value v) @trusted
{
    import std.algorithm.sorting : sort;
    import std.algorithm.mutation : SwapStrategy;

    auto seq = sequenceView(v);
    if (seq.length == 0)
        return Value.fromList(null);

    bool allNumbers = true, allStrings = true;
    foreach (ref e; seq)
    {
        if (!e.isNumber) allNumbers = false;
        if (e.kind != Kind.str) allStrings = false;
    }
    if (!allNumbers && !allStrings)
        throw typeError("cannot sort a mixed sequence");

    auto r = seq.dup;
    if (allNumbers)
    {
        r.sort!((a, b) => compareValues(a, b) < 0, SwapStrategy.stable)();
        return Value.fromList(r);
    }

    struct Keyed { string key; Value v; }
    auto keyed = new Keyed[r.length];
    foreach (i, ref e; r)
        keyed[i] = Keyed(mapAscii(e.s, false), e);
    keyed.sort!((a, b) => a.key < b.key, SwapStrategy.stable)();
    foreach (i, ref k; keyed)
        r[i] = k.v;
    return Value.fromList(r);
}

/// The `int` filter.
long toInt(Value v) @trusted
{
    switch (v.kind)
    {
        case Kind.integer:
        case Kind.boolean:  return v.i;
        case Kind.floating: return truncate(v.d);
        case Kind.str:      return parseIntString(v.s);
        default:            return 0;
    }
}

private long truncate(double d) pure nothrow @safe @nogc
{
    if (d >= 9.223372036854775807e18) return long.max;
    if (d <= -9.223372036854775808e18) return long.min;
    return cast(long) d;
}

private long parseIntString(string raw) @trusted
{
    auto s = trimSpace(raw);
    if (s.length == 0) return 0;
    size_t i = 0;
    bool neg = false;
    if (s[0] == '+' || s[0] == '-') { neg = s[0] == '-'; i = 1; }

    // [+-]?[0-9]+
    size_t j = i;
    while (j < s.length && s[j] >= '0' && s[j] <= '9') ++j;
    if (j == s.length && j > i)
    {
        ulong acc = 0;
        bool overflow = false;
        foreach (c; s[i .. j])
        {
            immutable d = c - '0';
            if (acc > (ulong.max - d) / 10) { overflow = true; break; }
            acc = acc * 10 + d;
        }
        if (!overflow)
        {
            if (!neg && acc <= long.max) return cast(long) acc;
            if (neg && acc <= cast(ulong) long.max + 1) return cast(long)(0UL - acc);
        }
        return neg ? long.min : long.max;
    }

    // [+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?
    size_t k = i;
    size_t intDigits = 0, fracDigits = 0;
    while (k < s.length && s[k] >= '0' && s[k] <= '9') { ++k; ++intDigits; }
    if (k < s.length && s[k] == '.')
    {
        ++k;
        while (k < s.length && s[k] >= '0' && s[k] <= '9') { ++k; ++fracDigits; }
    }
    if (intDigits == 0 && fracDigits == 0) return 0;
    if (k < s.length && (s[k] == 'e' || s[k] == 'E'))
    {
        ++k;
        if (k < s.length && (s[k] == '+' || s[k] == '-')) ++k;
        size_t expDigits = 0;
        while (k < s.length && s[k] >= '0' && s[k] <= '9') { ++k; ++expDigits; }
        if (expDigits == 0) return 0;
    }
    if (k != s.length) return 0;

    char[64] tmp = void;
    if (s.length >= tmp.length) return 0;
    tmp[0 .. s.length] = s[];
    tmp[s.length] = '\0';
    return truncate(strtod(tmp.ptr, null));
}

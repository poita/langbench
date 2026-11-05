/++
    The high-level API: compile a pattern once, then search subjects.

    ---
    import regex;

    auto re = new Regex("(a|ab)(c|bcd)(d*)");
    auto m = re.search("abcd");
    assert(m.matched && m.begin == 0 && m.end == 4);
    assert(m.group(2) == Span(1, 4));
    ---
+/
module regex.pattern;

import regex.compiler;
import regex.parser;
import regex.program;
import regex.vm;

/// A half-open range `[begin, end)` of subject offsets.
struct Span
{
    /// Offset of the first character, or -1 when unset.
    int begin = -1;
    /// Offset one past the last character, or -1 when unset.
    int end = -1;

    /// Whether the span holds a value (a group that took part in the match).
    bool isSet() const @safe pure nothrow @nogc
    {
        return begin >= 0;
    }
}

/// The result of a search.
struct Match
{
    /// Whether the pattern matched.
    bool matched;
    /// Offset where the match starts.
    int begin;
    /// Exclusive offset where the match ends.
    int end;
    /// Capture groups 1..G, in order (`groups[0]` is group 1).
    Span[] groups;

    /// Group `g` (1-based). Unset groups have `isSet == false`.
    Span group(size_t g) const @safe pure nothrow @nogc
    {
        return groups[g - 1];
    }
}

/++
    A compiled regular expression with Perl-style leftmost, greedy,
    ordered-choice semantics and capturing groups.

    The supported syntax is: literals, `.`, `^`, `$`, classes `[...]`, the
    escapes `\d \D \w \W \s \S` and escaped punctuation, groups `(...)`,
    alternation `|` and the quantifiers `* + ? {n} {n,} {n,m}`.

    A `Regex` is immutable once built and may be shared; `search` without an
    explicit `Matcher` allocates a fresh one on every call.
+/
final class Regex
{
    private Program program;

    /// Compile `pattern`. Throws `RegexException` if it is not valid.
    this(const(char)[] pattern) @safe
    {
        program = compile(parse(pattern));
    }

    /// Number of capturing groups.
    int groupCount() const @safe pure nothrow @nogc
    {
        return program.groupCount;
    }

    /// The compiled program (for tools and tests).
    ref const(Program) compiled() const @safe pure nothrow @nogc
    {
        return program;
    }

    /// Find the first match in `subject`.
    Match search(const(char)[] subject) const
    {
        Matcher m;
        return search(subject, m);
    }

    /// Like `search`, reusing the buffers of `matcher`.
    Match search(const(char)[] subject, ref Matcher matcher) const @trusted
    {
        Match r;
        if (!matcher.search(program, cast(const(ubyte)[]) subject))
            return r;
        r.matched = true;
        r.begin = matcher.matchStart;
        r.end = matcher.matchEnd;
        r.groups = new Span[program.groupCount];
        foreach (g; 1 .. program.groupCount + 1)
            r.groups[g - 1] = Span(matcher.groupStart(g), matcher.groupEnd(g));
        return r;
    }

    /// Whether the pattern matches anywhere in `subject`.
    bool matches(const(char)[] subject) const
    {
        Matcher m;
        return m.search(program, cast(const(ubyte)[]) subject);
    }
}

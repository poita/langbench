/**
 * Public interface of the engine.
 *
 * ---
 * auto re = new Regex("(a|ab)(c|bcd)(d*)");
 * auto m = re.match("abcd");
 * assert(m.matched && m.start == 0 && m.end == 4);
 * assert(m.group(2).start == 1 && m.group(2).end == 4);
 * ---
 */
module regex.regex;

import regex.compiler;
import regex.exception;
import regex.program;
import regex.vm;

/// The span of one capture group.
struct Capture
{
    /// Whether the group took part in the match.
    bool set;
    /// Start offset (inclusive) of the captured text.
    size_t start;
    /// End offset (exclusive) of the captured text.
    size_t end;
}

/// The result of matching a pattern against a subject.
struct Match
{
    /// True if the pattern matched somewhere in the subject.
    bool matched;
    /// Start offset of the overall match (valid if `matched`).
    size_t start;
    /// End offset (exclusive) of the overall match (valid if `matched`).
    size_t end;
    /// Captures for groups 1..G (`captures[0]` is group 1).
    Capture[] captures;

    /// Convertible to bool: true if matched.
    bool opCast(T : bool)() const pure nothrow @nogc @safe
    {
        return matched;
    }

    /// The capture of group `g` (1-based).
    Capture group(size_t g) const pure nothrow @nogc @safe
    in (g >= 1 && g <= captures.length)
    {
        return captures[g - 1];
    }

    /// The matched text of `subject` (the subject this match was taken from).
    inout(char)[] text(return inout(char)[] subject) const pure nothrow @nogc @safe
    {
        return subject[start .. end];
    }
}

/**
 * A compiled regular expression.
 *
 * Matching follows Perl-style leftmost, greedy, ordered-choice semantics.
 * A `Regex` keeps scratch buffers that are reused between calls, so one
 * instance must not be used from several threads at the same time.
 */
final class Regex
{
    private Program prog;
    private Matcher matcher;

    /// Compiles `pattern`. Throws `RegexException` if it is invalid.
    this(const(char)[] pattern) @safe
    {
        prog = compilePattern(pattern);
        matcher.reset(prog);
    }

    /// Number of capturing groups in the pattern.
    int groupCount() const pure nothrow @nogc @safe
    {
        return prog.groupCount;
    }

    /// Finds the first match in `subject`; allocates the result's captures.
    Match match(const(char)[] subject)
    {
        Match m;
        matchInto(subject, m);
        return m;
    }

    /**
     * Finds the first match in `subject`, storing it in `result`.
     * Reuses `result.captures`' storage, so repeated calls do not allocate.
     * Returns `result.matched`.
     */
    bool matchInto(const(char)[] subject, ref Match result)
    {
        auto s = cast(const(ubyte)[]) subject;
        immutable len = cast(int) s.length;
        result.matched = false;
        matcher.clearCaptures(prog);

        int start = 0;
        int end;
        while (start <= len)
        {
            if (prog.useFirstTable)
            {
                while (start < len && !prog.firstTable[s[start]])
                    start++;
                if (start >= len)
                    break; // a non-nullable pattern cannot match the empty tail
            }
            if (matcher.matchAt(prog, s, start, end))
            {
                result.matched = true;
                result.start = start;
                result.end = end;
                fillCaptures(result);
                return true;
            }
            if (prog.anchored)
                break;
            start++;
        }
        return false;
    }

    private void fillCaptures(ref Match result) nothrow
    {
        immutable g = prog.groupCount;
        if (result.captures.length != g)
            result.captures.length = g;
        foreach (i; 0 .. g)
        {
            immutable cs = matcher.slots[Program.capSlot(i + 1)];
            immutable ce = matcher.slots[Program.capSlot(i + 1) + 1];
            result.captures[i] = cs == unset ? Capture(false, 0, 0)
                : Capture(true, cs, ce);
        }
    }
}

unittest
{
    auto re = new Regex("(a|ab)(c|bcd)(d*)");
    auto m = re.match("abcd");
    assert(m && m.start == 0 && m.end == 4);
    assert(m.group(1) == Capture(true, 0, 1));
    assert(m.group(2) == Capture(true, 1, 4));
    assert(m.group(3) == Capture(true, 4, 4));
    assert(m.text("abcd") == "abcd");

    assert(!new Regex("a").match("bbb"));
    assert(new Regex("").match("").matched);
}

unittest
{
    // Reusing one Match across subjects must not leak state between them.
    auto re = new Regex("(a)|(b)");
    Match m;
    assert(re.matchInto("a", m) && m.group(1).set && !m.group(2).set);
    assert(re.matchInto("b", m) && !m.group(1).set && m.group(2).set);
    assert(!re.matchInto("c", m) && !m.matched);
    assert(re.matchInto("xb", m) && m.start == 1 && !m.group(1).set);
}

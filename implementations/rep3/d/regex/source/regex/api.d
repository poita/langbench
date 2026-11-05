/// Convenient high-level interface: compile a pattern once, match many subjects.
module regex.api;

import regex.compiler;
import regex.program;
import regex.vm;

/// The result of a search.
struct Match
{
    /// Whether the pattern matched anywhere.
    bool matched;
    /// Offsets of the whole match (valid if `matched`); `end` is exclusive.
    size_t start, end;
    /// Capture positions: group `g` (1-based) is `captures[2*g-2 .. 2*g]`; -1 means unset.
    int[] captures;

    /// Number of capture groups in the pattern.
    size_t groupCount() const pure nothrow @nogc @safe { return captures.length / 2; }

    /// True if group `g` (1-based) took part in the match.
    bool isSet(size_t g) const pure nothrow @nogc @safe
    {
        return matched && captures[2 * g - 2] >= 0;
    }

    /// Start offset of group `g` (1-based), or -1 if unset.
    int groupStart(size_t g) const pure nothrow @nogc @safe { return captures[2 * g - 2]; }

    /// Exclusive end offset of group `g` (1-based), or -1 if unset.
    int groupEnd(size_t g) const pure nothrow @nogc @safe { return captures[2 * g - 1]; }

    /// Text of the whole match within `subject`.
    inout(char)[] text(return inout(char)[] subject) const pure nothrow @nogc @safe
    {
        return subject[start .. end];
    }

    /// Text of group `g` within `subject` (empty if unset).
    inout(char)[] groupText(return inout(char)[] subject, size_t g) const pure nothrow @nogc @safe
    {
        return isSet(g) ? subject[groupStart(g) .. groupEnd(g)] : subject[0 .. 0];
    }
}

/**
 * A compiled regular expression.
 *
 * ---
 * auto re = new Regex(`(\w+)@(\w+)`);
 * auto m = re.search("mail bob@example now");
 * assert(m.matched && m.start == 5 && m.end == 16);
 * assert(m.groupText("mail bob@example now", 1) == "bob");
 * ---
 *
 * For high-volume use, keep a single `Matcher` and call `search` with it to
 * avoid per-call allocation.
 */
final class Regex
{
    private Program program_;

    /// Compiles `pattern`. Throws `RegexException` if it is invalid.
    this(const(char)[] pattern)
    {
        program_ = compile(pattern);
    }

    /// The compiled program.
    ref const(Program) program() const pure nothrow @nogc @safe { return program_; }

    /// Number of capture groups.
    int groupCount() const pure nothrow @nogc @safe { return program_.groupCount; }

    /// Searches `subject` using the caller's `matcher` (no allocation). Returns true on a match;
    /// results are read from the matcher.
    bool search(Matcher matcher, const(char)[] subject) const
    {
        return matcher.search(program_, subject);
    }

    /// Searches `subject` for the first match, returning a self-contained `Match`.
    Match search(const(char)[] subject) const
    {
        scope matcher = new Matcher;
        Match m;
        m.matched = matcher.search(program_, subject);
        if (m.matched)
        {
            m.start = matcher.matchStart;
            m.end = matcher.matchEnd;
        }
        m.captures = matcher.captures.dup;
        return m;
    }
}

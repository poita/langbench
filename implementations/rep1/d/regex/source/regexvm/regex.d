/// The public face of the library: compile a pattern once, match many
/// subjects.
module regexvm.regex;

import regexvm.ast;
import regexvm.compiler;
import regexvm.errors;
import regexvm.parser;
import regexvm.program;
import regexvm.vm;

/// The half-open range `[begin, end)` captured by a group.
struct Span
{
    size_t begin;  /// offset of the first captured byte
    size_t end;    /// offset one past the last captured byte
    bool isSet;    /// false if the group did not take part in the match

    /// The captured text of `subject` (empty if unset).
    inout(char)[] of(return scope inout(char)[] subject) const pure nothrow @nogc @safe
    {
        return isSet ? subject[begin .. end] : subject[0 .. 0];
    }
}

/// Result of a search.
struct Match
{
    bool matched;   /// true if the pattern matched somewhere in the subject
    size_t begin;   /// start offset of the match
    size_t end;     /// exclusive end offset of the match
    Span[] groups;  /// one entry per capture group, `groups[0]` is group 1

    /// Convenience: `matched` as a condition.
    bool opCast(T : bool)() const pure nothrow @nogc @safe { return matched; }
}

/// A compiled regular expression.
///
/// Matching follows Perl-style leftmost, greedy, ordered-choice semantics and
/// reports the first match together with every capture group's position.
/// Instances own reusable scratch memory, so a single `Regex` must not be
/// used from several threads at once.
///
/// Example:
/// ---
/// auto re = new Regex(`(a|ab)(c|bcd)(d*)`);
/// auto m = re.matchFirst("abcd");
/// assert(m.matched && m.begin == 0 && m.end == 4);
/// assert(m.groups[1].of("abcd") == "bcd");
/// ---
final class Regex
{
    private string pattern_;
    private Program program_;
    private Machine machine_;

    /// Parses and compiles `pattern`.
    /// Throws: `RegexException` if the pattern is invalid.
    this(const(char)[] pattern)
    {
        pattern_ = pattern.idup;
        auto ast = parse(pattern);
        program_ = compile(ast);
        machine_ = new Machine(program_);
    }

    /// The source pattern.
    string pattern() const pure nothrow @nogc @safe { return pattern_; }

    /// Number of capturing groups.
    size_t groupCount() const pure nothrow @nogc @safe { return program_.groupCount; }

    /// The compiled program (for inspection and testing).
    ref const(Program) program() const pure nothrow @nogc @safe { return program_; }

    /// Finds the first match in `subject`.
    Match matchFirst(const(char)[] subject)
    {
        Match m;
        matchFirst(subject, m);
        return m;
    }

    /// Finds the first match in `subject`, storing it in `m` and reusing
    /// `m.groups` storage.  Returns `m.matched`.
    bool matchFirst(const(char)[] subject, ref Match m) @trusted
    {
        int start;
        const found = machine_.search(cast(const(ubyte)[]) subject, start);
        m.matched = found;
        if (!found)
            return false;
        m.begin = start;
        m.end = machine_.matchEnd;
        const caps = machine_.captures;
        const g = caps.length / 2;
        m.groups.length = g;
        foreach (i; 0 .. g)
        {
            const b = caps[2 * i];
            m.groups[i] = b < 0 ? Span.init
                                : Span(b, caps[2 * i + 1], true);
        }
        return true;
    }

    /// True iff the pattern matches anywhere in `subject`.
    bool test(const(char)[] subject) @trusted
    {
        int start;
        return machine_.search(cast(const(ubyte)[]) subject, start);
    }
}

/// The backtracking matcher: a `Regex` object that searches subjects.
module btregex.engine;

import btregex.analysis;
import btregex.ast;
import btregex.charset;
import btregex.parser;
import btregex.program;

/// Offsets of a capture group in the subject; `start == -1` when unset.
struct Group
{
    long start = -1;
    long end = -1;

    /// True if the group took part in the match.
    bool isSet() const pure nothrow @nogc @safe
    {
        return start >= 0;
    }
}

/// Result of a search.
struct Match
{
    /// True if the pattern matched.
    bool matched;
    /// Offsets of the overall match (end is exclusive).
    size_t start, end;
    /// Capture groups 1..G (`groups[0]` is group 1).
    Group[] groups;
}

/// A compiled regular expression.
///
/// Matching follows Perl-style leftmost, greedy, ordered-choice semantics.
/// A `Regex` owns scratch buffers that are reused between searches, so one
/// instance must not be used from several threads at once.
final class Regex
{
    private Program prog;
    private StartInfo start;
    private int[] regs;

    private struct Choice
    {
        int pc;
        int pos;
        int trailLen;
    }

    private struct TrailEntry
    {
        int reg;
        int old;
    }

    private Choice[] choices;
    private TrailEntry[] trail;
    private size_t trailLen;

    /// Compiles `pattern`. Throws `RegexException` if it is invalid.
    this(const(char)[] pattern) @safe
    {
        auto parsed = parse(pattern);
        prog = compile(parsed.root, parsed.groupCount);
        start = analyse(parsed.root);
        regs = new int[prog.regCount];
        regs[] = -1;
        choices = new Choice[256];
        trail = new TrailEntry[256];
    }

    /// Number of capturing groups in the pattern.
    @property int groupCount() const pure nothrow @nogc @safe
    {
        return prog.groups;
    }

    /// Finds the first match in `subject`.
    Match search(const(char)[] subject) @safe
    {
        Match m;
        search(subject, m);
        return m;
    }

    /// Finds the first match in `subject`, storing it in `m` (reusing
    /// `m.groups` storage). Returns whether a match was found.
    bool search(const(char)[] subject, ref Match m) @trusted
    {
        const len = subject.length;
        assert(len < int.max);
        const s = cast(const(ubyte)*) subject.ptr;
        const anchored = start.anchoredStart;
        const nullable = start.nullable;
        const first = &start.first;
        foreach (i; 0 .. len + 1)
        {
            if (anchored && i > 0)
                break;
            if (!nullable && (i == len || !first.has(s[i])))
                continue;
            int end = run(s, cast(int) len, cast(int) i);
            if (end >= 0)
            {
                m.matched = true;
                m.start = i;
                m.end = end;
                m.groups.length = prog.groups;
                foreach (g; 0 .. prog.groups)
                {
                    m.groups[g].start = regs[2 * g];
                    m.groups[g].end = regs[2 * g + 1];
                }
                undoTo(0);
                return true;
            }
        }
        m.matched = false;
        m.start = m.end = 0;
        m.groups.length = 0;
        return false;
    }

    /// Restores registers to the values they had when the trail had `to` entries.
    private void undoTo(size_t to) nothrow @nogc @trusted
    {
        auto t = trail.ptr;
        auto r = regs.ptr;
        while (trailLen > to)
        {
            --trailLen;
            r[t[trailLen].reg] = t[trailLen].old;
        }
    }

    private void setReg(int reg, int value) nothrow @trusted
    {
        if (trailLen == trail.length)
            trail.length = trail.length * 2;
        trail[trailLen++] = TrailEntry(reg, regs[reg]);
        regs[reg] = value;
    }

    /// Runs the program at `startPos`. Returns the end offset or -1. On
    /// failure all registers are restored; on success the capture registers
    /// hold the result and the caller must call `undoTo(0)`.
    private int run(const(ubyte)* s, int len, int startPos) nothrow @trusted
    {
        const code = prog.code.ptr;
        const sets = prog.sets.ptr;
        int pc = 0;
        int pos = startPos;
        size_t sp = 0;
        while (true)
        {
            const ins = &code[pc];
            final switch (ins.op)
            {
            case Op.char_:
                if (pos < len && s[pos] == ins.ch)
                {
                    pos++;
                    pc++;
                    continue;
                }
                break;
            case Op.any:
                if (pos < len)
                {
                    pos++;
                    pc++;
                    continue;
                }
                break;
            case Op.set:
                if (pos < len && sets[ins.a].has(s[pos]))
                {
                    pos++;
                    pc++;
                    continue;
                }
                break;
            case Op.bol:
                if (pos == 0)
                {
                    pc++;
                    continue;
                }
                break;
            case Op.eol:
                if (pos == len)
                {
                    pc++;
                    continue;
                }
                break;
            case Op.split:
                if (sp == choices.length)
                    choices.length = choices.length * 2;
                choices[sp++] = Choice(ins.b, pos, cast(int) trailLen);
                pc = ins.a;
                continue;
            case Op.jmp:
                pc = ins.a;
                continue;
            case Op.setReg:
                setReg(ins.a, pos);
                pc++;
                continue;
            case Op.chkEmpty:
                pc = (regs[ins.a] == pos) ? ins.b : pc + 1;
                continue;
            case Op.groupEnd:
                {
                    const g = 2 * (ins.a - 1);
                    setReg(g, regs[ins.b]);
                    setReg(g + 1, pos);
                    pc++;
                    continue;
                }
            case Op.match:
                return pos;
            }
            // Failure: backtrack to the most recent choice point.
            if (sp == 0)
            {
                undoTo(0);
                return -1;
            }
            const c = choices[--sp];
            undoTo(c.trailLen);
            pc = c.pc;
            pos = c.pos;
        }
    }
}

unittest
{
    auto m = new Regex("(a|ab)(c|bcd)(d*)").search("abcd");
    assert(m.matched && m.start == 0 && m.end == 4);
    assert(m.groups == [Group(0, 1), Group(1, 4), Group(4, 4)]);
}

unittest
{
    // Deep backtracking stack: `.*` over a long subject.
    import std.array : replicate;

    auto re = new Regex("(.*)x");
    auto subj = "a".replicate(10_000);
    assert(!re.search(subj).matched);
    auto m = new Regex(".*").search(subj);
    assert(m.matched && m.end == 10_000);
}

unittest
{
    // Search state is clean between calls.
    auto re = new Regex("(a)|b");
    auto m1 = re.search("a");
    auto m2 = re.search("b");
    assert(m1.groups[0].isSet && !m2.groups[0].isSet);
    assert(!re.search("c").matched);
    assert(re.search("a").groups[0] == Group(0, 1));
}

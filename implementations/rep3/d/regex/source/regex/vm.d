/// The backtracking interpreter.
module regex.vm;

import regex.program;

/// A pending alternative on the backtrack stack.
private struct Choice
{
    int pc;   /// where to resume
    int pos;  /// subject position to resume at (for loops: the current end)
    int tp;   /// trail length to restore
    int low;  /// -1 for `split`; for char loops the lowest allowed end
}

/// An undo-trail entry: slot `slot` previously held `old`.
private struct TrailEntry
{
    int slot;
    int old;
}

/**
 * Runs compiled programs against subjects.
 *
 * A `Matcher` owns the backtrack stack, undo trail and capture array, and
 * reuses them from one search to the next (they only grow), so matching many
 * subjects allocates nothing in steady state. A single `Matcher` may be used
 * with any number of different programs, but not from several threads at once.
 */
final class Matcher
{
    private Choice[] stack = new Choice[1024];
    private TrailEntry[] trail = new TrailEntry[1024];
    private int[] slots;
    private int groups;
    private int matchStart_, matchEnd_;

    /**
     * Finds the first match of `prog` in `subject`.
     *
     * Returns: true if there is a match; results are then available through
     * `matchStart`, `matchEnd` and `captures`.
     */
    bool search(ref const Program prog, const(char)[] subject) @trusted
    {
        const(ubyte)[] s = cast(const(ubyte)[]) subject;
        const n = cast(int) s.length;
        groups = prog.groupCount;
        if (slots.length < prog.slotCount)
            slots.length = prog.slotCount;
        const ncap = 2 * prog.groupCount;

        if (prog.anchored)
            return tryStart(prog, s, 0, ncap);

        if (prog.useFirstSet)
        {
            const ubyte* first = prog.firstSet.ptr;
            int st = 0;
            for (;;)
            {
                while (st < n && !first[s[st]])
                    ++st;
                if (st >= n)
                    return false;
                if (tryStart(prog, s, st, ncap))
                    return true;
                ++st;
            }
        }
        foreach (st; 0 .. n + 1)
            if (tryStart(prog, s, st, ncap))
                return true;
        return false;
    }

    /// Start offset of the last match found.
    int matchStart() const pure nothrow @nogc @safe { return matchStart_; }

    /// Exclusive end offset of the last match found.
    int matchEnd() const pure nothrow @nogc @safe { return matchEnd_; }

    /**
     * Capture positions of the last match: for group `g` (1-based),
     * `captures[2*g-2]` and `captures[2*g-1]` are its start and end, or -1 if
     * the group is unset. The slice is valid until the next search.
     */
    const(int)[] captures() const pure nothrow @nogc @safe { return slots[0 .. 2 * groups]; }

    private bool tryStart(ref const Program prog, const(ubyte)[] s, int start, int ncap) @trusted
    {
        slots[0 .. ncap] = -1;
        if (run(prog, s, start))
        {
            matchStart_ = start;
            return true;
        }
        return false;
    }

    private bool run(ref const Program prog, const(ubyte)[] s, int start) @system
    {
        const Inst* code = prog.code.ptr;
        const n = cast(int) s.length;
        int* regs = slots.ptr;
        Choice[] stk = stack;
        TrailEntry[] trl = trail;
        size_t sp = 0, tp = 0;
        int pc = 0, pos = start;

        for (;;)
        {
            const Inst* ip = code + pc;
            switch (ip.op)
            {
            case Op.char_:
                if (pos < n && s[pos] == ip.a)
                {
                    ++pos;
                    ++pc;
                    continue;
                }
                goto fail;
            case Op.any:
                if (pos < n)
                {
                    ++pos;
                    ++pc;
                    continue;
                }
                goto fail;
            case Op.class_:
                if (pos < n && prog.sets[ip.a][s[pos]])
                {
                    ++pos;
                    ++pc;
                    continue;
                }
                goto fail;
            case Op.bol:
                if (pos == 0)
                {
                    ++pc;
                    continue;
                }
                goto fail;
            case Op.eol:
                if (pos == n)
                {
                    ++pc;
                    continue;
                }
                goto fail;
            case Op.split:
                if (sp == stk.length)
                {
                    stack.length = stk.length * 2;
                    stk = stack;
                }
                stk[sp++] = Choice(ip.b, pos, cast(int) tp, -1);
                pc = ip.a;
                continue;
            case Op.jmp:
                pc = ip.a;
                continue;
            case Op.save:
            case Op.mark:
                if (tp == trl.length)
                {
                    trail.length = trl.length * 2;
                    trl = trail;
                }
                trl[tp++] = TrailEntry(ip.a, regs[ip.a]);
                regs[ip.a] = pos;
                ++pc;
                continue;
            case Op.check:
                pc = (regs[ip.a] == pos) ? ip.b : pc + 1;
                continue;
            case Op.charLoop:
                {
                    const lo = ip.c;
                    const limit = (ip.d < 0 || ip.d > n - pos) ? n : pos + ip.d;
                    int e = pos;
                    final switch (cast(LoopKind) ip.a)
                    {
                    case LoopKind.char_:
                        while (e < limit && s[e] == ip.b)
                            ++e;
                        break;
                    case LoopKind.any:
                        e = limit;
                        break;
                    case LoopKind.class_:
                        const ubyte* t = prog.sets[ip.b].ptr;
                        while (e < limit && t[s[e]])
                            ++e;
                        break;
                    }
                    const low = pos + lo;
                    if (e < low)
                        goto fail;
                    if (e > low)
                    {
                        if (sp == stk.length)
                        {
                            stack.length = stk.length * 2;
                            stk = stack;
                        }
                        stk[sp++] = Choice(pc + 1, e, cast(int) tp, low);
                    }
                    pos = e;
                    ++pc;
                    continue;
                }
            case Op.match:
                matchEnd_ = pos;
                return true;
            default:
                assert(0, "bad opcode");
            }
        fail:
            if (sp == 0)
                return false;
            {
                Choice* c = &stk[sp - 1];
                const target = c.tp;
                while (tp > target)
                {
                    --tp;
                    regs[trl[tp].slot] = trl[tp].old;
                }
                pc = c.pc;
                if (c.low < 0)
                {
                    pos = c.pos;
                    --sp;
                }
                else
                {
                    pos = c.pos - 1;
                    if (pos > c.low)
                        c.pos = pos;
                    else
                        --sp;
                }
            }
        }
        assert(0);
    }
}

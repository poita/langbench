/// The backtracking virtual machine.
module regex.vm;

import regex.program;

/++
    Reusable matching state: the choice-point stack, the capture undo trail
    and the capture/register array. One `Matcher` can be shared by any number
    of programs; its buffers only grow.

    After a successful `search`, `matchStart`, `matchEnd`, `groupStart` and
    `groupEnd` describe the result until the next call.
+/
struct Matcher
{
    private static struct Choice
    {
        int pc; // where to resume
        int pos; // subject position (for charLoop: the end last continued at)
        int trail; // trail length to restore
        int low; // -1 for a plain split; otherwise the lowest allowed charLoop end
    }

    private static struct TrailEntry
    {
        int slot;
        int old;
    }

    private Choice[] stack = new Choice[256];
    private TrailEntry[] trail = new TrailEntry[256];
    private int[] slots;
    private int groups;

    /// Start offset of the last match.
    int matchStart;
    /// Exclusive end offset of the last match.
    int matchEnd;

    /// Start of group `g` (1-based) in the last match, or -1 if unset.
    int groupStart(int g) const @safe pure nothrow @nogc
    {
        return slots[2 * (g - 1)];
    }

    /// Exclusive end of group `g` (1-based) in the last match, or -1 if unset.
    int groupEnd(int g) const @safe pure nothrow @nogc
    {
        return slots[2 * (g - 1) + 1];
    }

    /++
        Find the first match of `prog` in `subject`, trying start positions
        left to right. Returns whether a match was found.
    +/
    bool search(ref const Program prog, const(ubyte)[] subject)
    {
        if (slots.length < prog.slotCount)
            slots.length = prog.slotCount;
        groups = prog.groupCount;
        const n = cast(int) subject.length;
        const last = prog.anchored ? 0 : n;
        const filter = !prog.nullable;
        const first = prog.first.table.ptr;

        for (int start = 0; start <= last; ++start)
        {
            if (filter)
            {
                // Skip starts whose character cannot begin a match.
                while (start < n && !first[subject[start]])
                    ++start;
                if (start >= n)
                    return false;
            }
            slots[0 .. 2 * groups] = -1;
            const end = run(prog, subject, start);
            if (end >= 0)
            {
                matchStart = start;
                matchEnd = end;
                return true;
            }
        }
        return false;
    }

    /// Runs the program at `start`; returns the match end or -1.
    private int run(ref const Program prog, const(ubyte)[] s, int start) @system
    {
        const Inst* code = prog.code.ptr;
        const ubyte* sets = prog.sets.ptr;
        const ubyte* str = s.ptr;
        const n = cast(int) s.length;
        int* sl = slots.ptr;
        Choice* stk = stack.ptr;
        size_t stkCap = stack.length;
        TrailEntry* trl = trail.ptr;
        size_t trlCap = trail.length;
        size_t sp = 0;
        size_t tp = 0;
        int pc = 0;
        int pos = start;

        for (;;)
        {
            const Inst* ins = code + pc;
            final switch (ins.op)
            {
            case Op.char_:
                if (pos < n && str[pos] == ins.a)
                {
                    ++pos;
                    ++pc;
                    continue;
                }
                break;
            case Op.any:
                if (pos < n)
                {
                    ++pos;
                    ++pc;
                    continue;
                }
                break;
            case Op.set:
                if (pos < n && sets[ins.a * 256 + str[pos]])
                {
                    ++pos;
                    ++pc;
                    continue;
                }
                break;
            case Op.bol:
                if (pos == 0)
                {
                    ++pc;
                    continue;
                }
                break;
            case Op.eol:
                if (pos == n)
                {
                    ++pc;
                    continue;
                }
                break;
            case Op.split:
                if (sp == stkCap)
                {
                    stack.length = stkCap * 2;
                    stk = stack.ptr;
                    stkCap = stack.length;
                }
                stk[sp++] = Choice(ins.b, pos, cast(int) tp, -1);
                pc = ins.a;
                continue;
            case Op.jmp:
                pc = ins.a;
                continue;
            case Op.save, Op.mark:
                if (sp != 0) // with no choice point nothing can be undone
                {
                    if (tp == trlCap)
                    {
                        trail.length = trlCap * 2;
                        trl = trail.ptr;
                        trlCap = trail.length;
                    }
                    trl[tp++] = TrailEntry(ins.a, sl[ins.a]);
                }
                sl[ins.a] = pos;
                ++pc;
                continue;
            case Op.check:
                pc = (sl[ins.a] == pos) ? ins.b : pc + 1;
                continue;
            case Op.charLoop:
                {
                    const ubyte* tbl = sets + ins.c * 256;
                    int limit = n - pos;
                    if (ins.b >= 0 && ins.b < limit)
                        limit = ins.b;
                    int cnt = 0;
                    while (cnt < limit && tbl[str[pos + cnt]])
                        ++cnt;
                    if (cnt < ins.a)
                        break;
                    if (cnt > ins.a)
                    {
                        if (sp == stkCap)
                        {
                            stack.length = stkCap * 2;
                            stk = stack.ptr;
                            stkCap = stack.length;
                        }
                        stk[sp++] = Choice(pc + 1, pos + cnt, cast(int) tp, pos + ins.a);
                    }
                    pos += cnt;
                    ++pc;
                    continue;
                }
            case Op.match:
                return pos;
            }

            // Failure: resume the newest choice point.
            if (sp == 0)
                return -1;
            Choice* c = &stk[sp - 1];
            while (tp > c.trail)
            {
                --tp;
                sl[trl[tp].slot] = trl[tp].old;
            }
            pc = c.pc;
            if (c.low < 0)
            {
                pos = c.pos;
                --sp;
            }
            else
            {
                // Give back one character; keep the entry while ends remain.
                pos = c.pos - 1;
                if (pos > c.low)
                    c.pos = pos;
                else
                    --sp;
            }
        }
    }
}

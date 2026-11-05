/// The backtracking virtual machine.
///
/// A `Machine` interprets a compiled `Program` against subjects.  It keeps an
/// explicit choice-point stack and an undo trail for captures, both allocated
/// once and reused across subjects, so matching performs no per-subject or
/// per-start allocation (other than amortised growth of the two stacks).
module regexvm.vm;

import regexvm.charset;
import regexvm.program;

/// A saved alternative.  For a `split` entry `lo == -1` and execution resumes
/// at `pc` with position `pos`.  For a single-character loop `lo` is the
/// lowest allowed end, `pos` the end currently being tried, and `pc` the
/// instruction following the loop.
private struct Choice
{
    int pc;
    int pos;
    int trail;  // trail length to undo down to
    int lo;     // -1 for split, otherwise loop minimum end
}

/// An undo record: slot `slot` previously held `old`.
private struct TrailEntry
{
    int slot;
    int old;
}

/// Executes a program.  Not thread-safe; use one `Machine` per thread.
final class Machine
{
    private Program prog;
    private Choice[] stack;
    private TrailEntry[] trail;
    private int[] slots;

    /// End offset of the last successful `search`.
    int matchEnd;

    /// Creates a machine for `program`.
    this(Program program) pure nothrow @safe
    {
        prog = program;
        stack = new Choice[64];
        trail = new TrailEntry[64];
        slots = new int[prog.slotCount ? prog.slotCount : 1];
    }

    /// Capture slots of the last successful search: `[2g-2]`/`[2g-1]` are the
    /// start/end of group `g`, or -1 when unset.
    const(int)[] captures() const pure nothrow @nogc @safe
    {
        return slots[0 .. 2 * cast(size_t) prog.groupCount];
    }

    /// Finds the leftmost match in `s`.  On success returns true, stores the
    /// start in `matchStart`, the end in `matchEnd`, and fills `captures`.
    bool search(const(ubyte)[] s, out int matchStart) @trusted
    {
        assert(s.length < int.max);
        const n = cast(int) s.length;
        const ncap = 2 * cast(size_t) prog.groupCount;

        if (prog.anchored)
        {
            slots[0 .. ncap] = -1;
            if (run(s, 0))
            {
                matchStart = 0;
                return true;
            }
            return false;
        }

        int start = 0;
        const filter = prog.filterStarts;
        const table = prog.first.table.ptr;
        for (;;)
        {
            if (filter)
            {
                // A non-nullable pattern needs a byte at the start position.
                while (start < n && !table[s[start]])
                    ++start;
                if (start >= n)
                    return false;
            }
            slots[0 .. ncap] = -1;
            if (run(s, start))
            {
                matchStart = start;
                return true;
            }
            if (start >= n)
                return false;
            ++start;
        }
    }

    private void growStack() pure nothrow @safe { stack.length = stack.length * 2; }
    private void growTrail() pure nothrow @safe { trail.length = trail.length * 2; }

    /// Runs the program from `start`.  Returns true on a match.
    private bool run(const(ubyte)[] s, int start) @trusted
    {
        const code = prog.code.ptr;
        const sets = prog.sets.ptr;
        const n = cast(int) s.length;
        const subject = s.ptr;
        int* slots = this.slots.ptr;
        const regBase = 2 * prog.groupCount;
        size_t sp = 0;  // choice-stack height
        size_t tp = 0;  // trail height
        int pc = 0;
        int pos = start;

        for (;;)
        {
            const ins = &code[pc];
            final switch (ins.op)
            {
            case Op.char_:
                if (pos < n && subject[pos] == ins.a)
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
            case Op.set:
                if (pos < n && sets[ins.a].table[subject[pos]])
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
                if (sp == stack.length)
                    growStack();
                stack[sp++] = Choice(ins.b, pos, cast(int) tp, -1);
                pc = ins.a;
                continue;
            case Op.jmp:
                pc = ins.a;
                continue;
            case Op.save:
            case Op.mark:
            {
                const slot = ins.op == Op.save ? ins.a : regBase + ins.a;
                if (sp != 0)  // with no choice point there is nothing to undo
                {
                    if (tp == trail.length)
                        growTrail();
                    trail[tp++] = TrailEntry(slot, slots[slot]);
                }
                slots[slot] = pos;
                ++pc;
                continue;
            }
            case Op.check:
                pc = slots[regBase + ins.a] == pos ? ins.b : pc + 1;
                continue;
            case Op.charLoop:
            case Op.anyLoop:
            case Op.setLoop:
            {
                const lim = (ins.c < 0 || ins.c > n - pos) ? n : pos + ins.c;
                int e = pos;
                switch (ins.op)
                {
                case Op.charLoop:
                    while (e < lim && subject[e] == ins.a) ++e;
                    break;
                case Op.anyLoop:
                    e = lim;
                    break;
                case Op.setLoop:
                {
                    const tbl = sets[ins.a].table.ptr;
                    while (e < lim && tbl[subject[e]]) ++e;
                    break;
                }
                default:
                    assert(0);
                }
                const lo = pos + ins.b;
                if (e < lo)
                    goto fail;
                if (e > lo)
                {
                    if (sp == stack.length)
                        growStack();
                    stack[sp++] = Choice(pc + 1, e, cast(int) tp, lo);
                }
                pos = e;
                ++pc;
                continue;
            }
            case Op.match:
                matchEnd = pos;
                return true;
            }

        fail:
            if (sp == 0)
                return false;
            {
                Choice* c = &stack[sp - 1];
                while (tp > c.trail)
                {
                    --tp;
                    slots[trail[tp].slot] = trail[tp].old;
                }
                pc = c.pc;
                if (c.lo < 0)
                {
                    pos = c.pos;
                    --sp;
                }
                else
                {
                    // give back one character; keep the entry while ends remain
                    pos = c.pos - 1;
                    if (pos > c.lo)
                        c.pos = pos;
                    else
                        --sp;
                }
            }
        }
        assert(0);
    }
}

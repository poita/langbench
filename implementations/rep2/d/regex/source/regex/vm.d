/**
 * The backtracking virtual machine.
 *
 * Implements the matching semantics of the specification with an explicit
 * backtrack stack, so recursion depth is never a concern. The stack holds two
 * kinds of entries: choice points (`pc >= 0`: resume at `pc` with position
 * `a`) and undo records (`pc < 0`: restore slot `a` to the value `b`).
 * Every write to a capture or loop-mark slot pushes an undo record, so a
 * failed alternative is undone at a cost proportional to its writes, and
 * after a failed attempt all slots are back to their initial state.
 */
module regex.vm;

import regex.program;

/// Marker stored in slots that hold no value.
enum unset = -1;

private struct Frame
{
    int pc; // >= 0: choice point; < 0: undo record
    int a;  // choice: position; undo: slot index
    int b;  // undo: old value
}

/// Reusable matcher state (slot array and backtrack stack) for one program.
struct Matcher
{
    /// Capture slots: `slots[2g], slots[2g+1]` is group `g`'s span, or `unset`.
    int[] slots;
    private Frame[] stack;

    /// Prepares the matcher for `prog`.
    void reset(ref const Program prog) pure nothrow @safe
    {
        slots.length = prog.slotCount;
        slots[] = unset;
        if (stack.length == 0)
            stack.length = 256;
    }

    /**
     * Attempts a match of `prog` against `s` starting exactly at `start`.
     * On success returns true, sets `end`, and leaves captures in `slots`;
     * on failure returns false and leaves `slots` fully reset.
     */
    bool matchAt(ref const Program prog, const(ubyte)[] s, int start, out int end) nothrow
    {
        const code = prog.code;
        immutable n = cast(int) s.length;
        auto slots = this.slots;
        auto stack = this.stack;
        size_t sp = 0;
        int pc = 0;
        int pos = start;

        // Pushes an undo record for `slot` and then assigns `value`.
        // (A nested function keeps the interpreter loop readable.)
        void write(int slot, int value) nothrow
        {
            if (sp == stack.length)
            {
                stack.length = stack.length * 2;
            }
            stack[sp++] = Frame(-1, slot, slots[slot]);
            slots[slot] = value;
        }

        for (;;)
        {
            final switch (code[pc].op)
            {
            case Op.literal:
                if (pos < n && s[pos] == code[pc].arg)
                {
                    pos++;
                    pc++;
                    continue;
                }
                break;
            case Op.any:
                if (pos < n)
                {
                    pos++;
                    pc++;
                    continue;
                }
                break;
            case Op.set:
                if (pos < n && prog.sets[code[pc].arg].contains(s[pos]))
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
                if (pos == n)
                {
                    pc++;
                    continue;
                }
                break;
            case Op.split:
                if (sp == stack.length)
                    stack.length = stack.length * 2;
                stack[sp++] = Frame(code[pc].arg, pos, 0);
                pc++;
                continue;
            case Op.jump:
                pc = code[pc].arg;
                continue;
            case Op.groupStart:
                write(prog.groupStartSlot(code[pc].arg), pos);
                pc++;
                continue;
            case Op.groupEnd:
                {
                    immutable g = code[pc].arg;
                    immutable startPos = slots[prog.groupStartSlot(g)];
                    write(Program.capSlot(g), startPos);
                    write(Program.capSlot(g) + 1, pos);
                    pc++;
                    continue;
                }
            case Op.mark:
                write(code[pc].arg, pos);
                pc++;
                continue;
            case Op.checkEmpty:
                pc = (slots[code[pc].arg] == pos) ? code[pc].arg2 : pc + 1;
                continue;
            case Op.accept:
                end = pos;
                // Keep stack storage for reuse; slots keep the captures.
                this.stack = stack;
                return true;
            }

            // Failure: unwind to the most recent choice point.
            for (;;)
            {
                if (sp == 0)
                {
                    this.stack = stack;
                    return false;
                }
                immutable f = stack[--sp];
                if (f.pc < 0)
                    slots[f.a] = f.b;
                else
                {
                    pc = f.pc;
                    pos = f.a;
                    break;
                }
            }
        }
    }

    /**
     * After a successful `matchAt`, the matcher's slots hold that match's
     * captures. Call this before the next subject to clear them.
     */
    void clearCaptures(ref const Program prog) pure nothrow @safe
    {
        // Only capture slots are ever read before being written.
        slots[0 .. 2 * (prog.groupCount + 1)] = unset;
    }
}

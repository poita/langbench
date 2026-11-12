/**
 * The compiled form of a pattern: a flat instruction list for the
 * backtracking virtual machine in $(MREF regex.vm).
 */
module regex.program;

import regex.charset;

/// Virtual-machine opcodes.
enum Op : ubyte
{
    /// Consume the byte `arg` or fail.
    literal,
    /// Consume any byte.
    any,
    /// Consume a byte that is a member of `sets[arg]`.
    set,
    /// Succeed only at subject position 0.
    bol,
    /// Succeed only at the end of the subject.
    eol,
    /// Continue at `pc + 1`; on failure resume at `arg`.
    split,
    /// Continue at `arg`.
    jump,
    /// Record the current position as the start of group `arg`.
    groupStart,
    /// Complete group `arg`: caps[arg] = (recorded start, current position).
    groupEnd,
    /// Store the current position in slot `arg` (start of an optional iteration).
    mark,
    /// If the position equals slot `arg`, the iteration was empty: jump to `arg2`.
    checkEmpty,
    /// The whole pattern matched.
    accept,
}

/// One VM instruction.
struct Inst
{
    Op op;
    int arg;
    int arg2;
}

/// A compiled pattern.
struct Program
{
    Inst[] code;
    CharSet[] sets;
    /// Number of capturing groups.
    int groupCount;
    /// Number of integer slots the VM needs (captures, group starts, loop marks).
    int slotCount;
    /// `firstTable[c]` is true if a match can begin with byte `c`.
    /// Only meaningful when `useFirstTable` is set.
    bool[256] firstTable;
    /// False if the pattern can match the empty string, so every start must be tried.
    bool useFirstTable;
    /// True if a match can only start at subject position 0.
    bool anchored;

    /// Slot index of the start of capture group `g` (end is the next slot).
    static int capSlot(int g) pure nothrow @nogc @safe
    {
        return 2 * g;
    }

    /// Slot holding the pending start of group `g`.
    int groupStartSlot(int g) const pure nothrow @nogc @safe
    {
        return 2 * (groupCount + 1) + g;
    }

    /// First slot used for loop marks.
    int loopBase() const pure nothrow @nogc @safe
    {
        return 3 * (groupCount + 1);
    }
}

/// Instruction set of the backtracking virtual machine.
module regex.program;

import regex.charset;

/// Opcodes. Operand meaning is listed per opcode (`a`, `b`, `c`, `d` of `Inst`).
enum Op : int
{
    char_,    /// a = character: match it, advance
    any,      /// match any character, advance
    class_,   /// a = index into `Program.sets`: match a member, advance
    bol,      /// succeed only at position 0
    eol,      /// succeed only at the end of the subject
    split,    /// a = preferred target, b = alternative (pushed as a choice point)
    jmp,      /// a = target
    save,     /// a = slot: store the position in the slot (undoable)
    mark,     /// a = slot: store the position in a loop register (undoable)
    check,    /// a = register slot, b = exit: jump to b if the position has not moved
    charLoop, /// a = LoopKind, b = operand, c = min, d = max (< 0: unbounded)
    match,    /// the whole pattern matched
}

/// What a `charLoop` repeats.
enum LoopKind : int
{
    char_, /// operand = character
    any,   /// operand unused
    class_ /// operand = set index
}

/// One fixed-size instruction.
struct Inst
{
    Op op;
    int a, b, c, d;
}

/// A compiled pattern.
struct Program
{
    Inst[] code;
    ubyte[256][] sets;     /// membership tables for `class_` / `LoopKind.class_`
    int groupCount;        /// number of capture groups
    int slotCount;         /// capture slots (2 per group) followed by loop registers
    bool anchored;         /// every match starts at position 0
    bool useFirstSet;      /// `firstSet` may be used to skip start positions
    ubyte[256] firstSet;   /// characters a match can begin with (valid if `useFirstSet`)
}

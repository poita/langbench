/// The flat program executed by the backtracking virtual machine.
module regex.program;

import regex.charset;

/// Virtual machine opcodes.
enum Op : ubyte
{
    char_, /// match the character `a`
    any, /// match any character
    set, /// match a character in set number `a`
    bol, /// succeed at position 0
    eol, /// succeed at the end of the subject
    split, /// try `a` first; on failure resume at `b`
    jmp, /// continue at `a`
    save, /// store the position in slot `a` (trailed)
    mark, /// store the position in slot `a`, a loop register (trailed)
    check, /// if the position equals slot `a`, continue at `b`
    charLoop, /// repeat set `c` between `a` and `b` times (`b` < 0: unbounded), greedily
    match, /// overall success
}

/// One fixed-size instruction.
struct Inst
{
    Op op;
    int a;
    int b;
    int c;
}

/// A compiled pattern.
struct Program
{
    Inst[] code;
    /// Character sets, `256` bytes each, referenced by index.
    ubyte[] sets;
    /// Number of capturing groups.
    int groupCount;
    /// Capture slots (`2 * groupCount`) followed by loop registers.
    int slotCount;
    /// Every match must start at position 0.
    bool anchored;
    /// The pattern can match the empty string.
    bool nullable;
    /// Characters that can begin a match (meaningful when `!nullable`).
    CharSet first;
}

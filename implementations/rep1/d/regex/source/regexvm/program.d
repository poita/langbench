/// The flat instruction set executed by the backtracking VM.
module regexvm.program;

import regexvm.charset;

/// Opcodes.  Operand meaning is given per opcode (`a`, `b`, `c` of `Inst`).
enum Op : ubyte
{
    char_,     /// match byte `a`
    any,       /// match any byte
    set,       /// match a byte in class `a`
    bol,       /// succeed only at position 0
    eol,       /// succeed only at the end of the subject
    split,     /// try pc `a` first; on failure resume at pc `b`
    jmp,       /// continue at pc `a`
    save,      /// slot `a` := position (trailed)
    mark,      /// register `a` := position (trailed)
    check,     /// if position == register `a`, continue at pc `b`
    charLoop,  /// greedy loop of byte `a`: min `b`, max `c` (-1 = unbounded)
    anyLoop,   /// greedy loop of any byte: min `b`, max `c`
    setLoop,   /// greedy loop of class `a`: min `b`, max `c`
    match,     /// the whole pattern matched
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
    Inst[] code;          /// instructions; execution starts at 0
    CharSet[] sets;       /// class table referenced by `Op.set`/`Op.setLoop`
    int groupCount;       /// number of capture groups
    int registerCount;    /// number of loop registers (`mark`/`check`)
    bool anchored;        /// every match must start at position 0
    bool filterStarts;    /// skip starts whose byte is not in `first`
    CharSet first;        /// bytes a match can begin with (if `filterStarts`)

    /// Number of integer slots: 2 per group followed by the loop registers.
    size_t slotCount() const pure nothrow @nogc @safe
    {
        return 2 * cast(size_t) groupCount + registerCount;
    }
}

/// Human-readable listing of a program (for tests and debugging).
string disassemble(const Program p)
{
    import std.format : format;
    import std.array : appender;

    auto sb = appender!string();
    foreach (i, ins; p.code)
    {
        final switch (ins.op)
        {
        case Op.char_:    sb.put(format("%d: char %s\n", i, cast(char) ins.a)); break;
        case Op.any:      sb.put(format("%d: any\n", i)); break;
        case Op.set:      sb.put(format("%d: set %d\n", i, ins.a)); break;
        case Op.bol:      sb.put(format("%d: bol\n", i)); break;
        case Op.eol:      sb.put(format("%d: eol\n", i)); break;
        case Op.split:    sb.put(format("%d: split %d, %d\n", i, ins.a, ins.b)); break;
        case Op.jmp:      sb.put(format("%d: jmp %d\n", i, ins.a)); break;
        case Op.save:     sb.put(format("%d: save %d\n", i, ins.a)); break;
        case Op.mark:     sb.put(format("%d: mark %d\n", i, ins.a)); break;
        case Op.check:    sb.put(format("%d: check %d -> %d\n", i, ins.a, ins.b)); break;
        case Op.charLoop: sb.put(format("%d: charloop %s {%d,%d}\n", i, cast(char) ins.a, ins.b, ins.c)); break;
        case Op.anyLoop:  sb.put(format("%d: anyloop {%d,%d}\n", i, ins.b, ins.c)); break;
        case Op.setLoop:  sb.put(format("%d: setloop %d {%d,%d}\n", i, ins.a, ins.b, ins.c)); break;
        case Op.match:    sb.put(format("%d: match\n", i)); break;
        }
    }
    return sb.data;
}

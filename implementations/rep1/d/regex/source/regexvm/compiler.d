/// Compiles a syntax tree into a flat backtracking-VM program.
module regexvm.compiler;

import regexvm.analysis;
import regexvm.ast;
import regexvm.charset;
import regexvm.errors;
import regexvm.program;

/// Upper bound on program length; guards against pathological counted
/// quantifier nesting such as `((a{100}){100}){100}`.
enum size_t maxProgramLength = 4_000_000;

/// Compiles `ast` into a `Program`, including the start-position filters.
/// Throws: `RegexException` if the expanded program would be too large.
Program compile(Ast ast)
{
    auto c = Compiler();
    c.program.groupCount = ast.groupCount;
    c.emitNode(ast.root);
    c.emit(Op.match);

    auto p = c.program;
    p.registerCount = c.registers;
    p.anchored = isAnchoredAtStart(ast.root);
    if (!p.anchored)
    {
        auto f = firstInfo(ast.root);
        if (!f.nullable && !f.set.isFull)
        {
            p.filterStarts = true;
            p.first = f.set;
        }
    }
    return p;
}

private struct Compiler
{
    Program program;
    int registers;

    int pc() const { return cast(int) program.code.length; }

    int emit(Op op, int a = 0, int b = 0, int c = 0)
    {
        if (program.code.length >= maxProgramLength)
            throw new RegexException("pattern expands to too large a program");
        program.code ~= Inst(op, a, b, c);
        return pc - 1;
    }

    int setIndex(Node n)
    {
        if (n.setIndex < 0)
        {
            n.setIndex = cast(int) program.sets.length;
            program.sets ~= n.set;
        }
        return n.setIndex;
    }

    void emitNode(Node n)
    {
        final switch (n.kind)
        {
        case NodeKind.literal: emit(Op.char_, n.ch); break;
        case NodeKind.any:     emit(Op.any); break;
        case NodeKind.set:     emit(Op.set, setIndex(n)); break;
        case NodeKind.bol:     emit(Op.bol); break;
        case NodeKind.eol:     emit(Op.eol); break;
        case NodeKind.seq:
            foreach (child; n.children)
                emitNode(child);
            break;
        case NodeKind.alt:
            emitAlt(n);
            break;
        case NodeKind.group:
            emit(Op.save, 2 * (n.group - 1));
            emitNode(n.children[0]);
            emit(Op.save, 2 * (n.group - 1) + 1);
            break;
        case NodeKind.repeat:
            emitRepeat(n);
            break;
        }
    }

    /// `split L1, L2; L1: b1; jmp end; L2: split ...; last branch; end:`
    void emitAlt(Node n)
    {
        int[] jumps;
        foreach (i, branch; n.children)
        {
            const last = i + 1 == n.children.length;
            if (last)
            {
                emitNode(branch);
                break;
            }
            const split = emit(Op.split, 0, 0);
            program.code[split].a = pc;
            emitNode(branch);
            jumps ~= emit(Op.jmp);
            program.code[split].b = pc;
        }
        foreach (j; jumps)
            program.code[j].a = pc;
    }

    void emitRepeat(Node n)
    {
        auto body_ = n.children[0];
        if (n.max == 0)
            return;  // x{0}: never runs the atom

        if (body_.isSingleChar)
        {
            const maxCount = n.max == unbounded ? -1 : n.max;
            final switch (body_.kind)
            {
            case NodeKind.literal: emit(Op.charLoop, body_.ch, n.min, maxCount); break;
            case NodeKind.any:     emit(Op.anyLoop, 0, n.min, maxCount); break;
            case NodeKind.set:     emit(Op.setLoop, setIndex(body_), n.min, maxCount); break;
            case NodeKind.bol, NodeKind.eol, NodeKind.seq, NodeKind.alt,
                 NodeKind.group, NodeKind.repeat:
                assert(0);
            }
            return;
        }

        // Mandatory iterations are always run, even when they match empty.
        foreach (_; 0 .. n.min)
            emitNode(body_);

        // mark/check only when an iteration may consume nothing.
        const guarded = isNullable(body_);
        int reg = -1;
        if (guarded)
            reg = registers++;

        int[] exits;  // check/split instructions whose exit target is patched

        if (n.max == unbounded)
        {
            // L: split body, exit; [mark r]; x; [check r -> exit]; jmp L; exit:
            const loop = emit(Op.split, 0, 0);
            program.code[loop].a = pc;
            if (guarded) emit(Op.mark, reg);
            emitNode(body_);
            if (guarded) exits ~= emit(Op.check, reg, 0);
            emit(Op.jmp, loop);
            program.code[loop].b = pc;
            foreach (e; exits)
                program.code[e].b = pc;
            return;
        }

        // max - min nested optional copies, all leaving through one exit.
        int[] splits;
        foreach (_; n.min .. n.max)
        {
            const s = emit(Op.split, 0, 0);
            program.code[s].a = pc;
            splits ~= s;
            if (guarded) emit(Op.mark, reg);
            emitNode(body_);
            if (guarded) exits ~= emit(Op.check, reg, 0);
        }
        foreach (s; splits)
            program.code[s].b = pc;
        foreach (e; exits)
            program.code[e].b = pc;
    }
}

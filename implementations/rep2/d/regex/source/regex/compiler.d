/// Compiles a syntax tree into a backtracking-VM program.
module regex.compiler;

import regex.analysis;
import regex.ast;
import regex.charset;
import regex.parser;
import regex.program;

/// Compile a parsed pattern into a `Program`.
Program compile(Parsed parsed) @safe
{
    auto c = Compiler(parsed.groupCount);
    c.emitNode(parsed.root);
    c.emit(Op.match);

    Program p;
    p.code = c.code;
    p.sets = c.sets;
    p.groupCount = parsed.groupCount;
    p.slotCount = 2 * parsed.groupCount + c.registers;
    p.anchored = anchoredAtStart(parsed.root);
    p.nullable = firstSet(parsed.root, p.first);
    return p;
}

private struct Compiler
{
    Inst[] code;
    ubyte[] sets;
    int registers;
    int groupSlots;

    this(int groups) @safe pure nothrow @nogc
    {
        groupSlots = 2 * groups;
    }

    int here() const @safe pure nothrow @nogc
    {
        return cast(int) code.length;
    }

    int emit(Op op, int a = 0, int b = 0, int c = 0) @safe pure nothrow
    {
        code ~= Inst(op, a, b, c);
        return here - 1;
    }

    int addSet(const ref CharSet s) @safe pure nothrow
    {
        const idx = cast(int)(sets.length / 256);
        sets ~= s.table[];
        return idx;
    }

    void emitNode(Node n) @safe
    {
        final switch (n.kind)
        {
        case NodeKind.literal:
            emit(Op.char_, n.ch);
            break;
        case NodeKind.any:
            emit(Op.any);
            break;
        case NodeKind.set:
            emit(Op.set, addSet(n.set));
            break;
        case NodeKind.bol:
            emit(Op.bol);
            break;
        case NodeKind.eol:
            emit(Op.eol);
            break;
        case NodeKind.seq:
            foreach (c; n.children)
                emitNode(c);
            break;
        case NodeKind.alt:
            emitAlt(n);
            break;
        case NodeKind.group:
            const slot = 2 * (n.groupIndex - 1);
            emit(Op.save, slot);
            emitNode(n.children[0]);
            emit(Op.save, slot + 1);
            break;
        case NodeKind.repeat:
            emitRepeat(n);
            break;
        }
    }

    void emitAlt(Node n) @safe
    {
        int[] jumps;
        foreach (i, branch; n.children)
        {
            const last = i + 1 == n.children.length;
            int split = -1;
            if (!last)
                split = emit(Op.split, here + 1);
            emitNode(branch);
            if (!last)
            {
                jumps ~= emit(Op.jmp);
                code[split].b = here;
            }
        }
        foreach (j; jumps)
            code[j].a = here;
    }

    void emitRepeat(Node n) @safe
    {
        auto body_ = n.children[0];
        if (n.max == 0)
            return; // x{0} never runs x
        if (body_.isSingleChar)
        {
            if (n.min == 1 && n.max == 1)
            {
                emitNode(body_);
                return;
            }
            const cs = body_.charSet;
            emit(Op.charLoop, n.min, n.max, addSet(cs));
            return;
        }

        foreach (_; 0 .. n.min)
            emitNode(body_);

        // Only bodies that can match the empty string need the progress check.
        const needCheck = nullable(body_);
        const reg = needCheck ? groupSlots + registers++ : -1;

        if (n.max == unbounded)
        {
            const loop = emit(Op.split, here + 1);
            if (needCheck)
                emit(Op.mark, reg);
            emitNode(body_);
            int chk = -1;
            if (needCheck)
                chk = emit(Op.check, reg);
            emit(Op.jmp, loop);
            code[loop].b = here;
            if (needCheck)
                code[chk].b = here;
        }
        else
        {
            int[] splits;
            int[] checks;
            foreach (_; 0 .. n.max - n.min)
            {
                splits ~= emit(Op.split, here + 1);
                if (needCheck)
                    emit(Op.mark, reg);
                emitNode(body_);
                if (needCheck)
                    checks ~= emit(Op.check, reg);
            }
            foreach (s; splits)
                code[s].b = here;
            foreach (c; checks)
                code[c].b = here;
        }
    }
}

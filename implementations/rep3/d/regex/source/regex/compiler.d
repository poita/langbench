/// Compiles a syntax tree into a backtracking-VM `Program`.
module regex.compiler;

import regex.analysis;
import regex.ast;
import regex.charset;
import regex.parser;
import regex.program;

/// Upper bound on program size, to bound memory for hostile patterns.
enum maxProgramSize = 2_000_000;

/**
 * Parses and compiles `pattern`.
 *
 * Throws: `RegexException` if the pattern is invalid or expands too far.
 */
Program compile(const(char)[] pattern) @safe
{
    return compile(parse(pattern));
}

/// Compiles an already parsed pattern.
Program compile(ParsedPattern parsed) @safe
{
    auto c = Compiler(parsed.groupCount);
    c.gen(parsed.root);
    c.emit(Op.match);

    Program p;
    p.code = c.code;
    p.sets = c.sets;
    p.groupCount = parsed.groupCount;
    p.slotCount = c.nextSlot;
    p.anchored = isAnchored(parsed.root);

    CharSet first;
    const nullable = firstChars(parsed.root, first);
    if (!p.anchored && !nullable && !first.isFull())
    {
        p.useFirstSet = true;
        first.toTable(p.firstSet);
    }
    return p;
}

private struct Compiler
{
    Inst[] code;
    ubyte[256][] sets;
    int nextSlot;

    this(int groupCount) pure nothrow @safe
    {
        nextSlot = 2 * groupCount;
    }

    int here() const pure nothrow @nogc @safe { return cast(int) code.length; }

    int emit(Op op, int a = 0, int b = 0, int c = 0, int d = 0) @safe
    {
        if (code.length >= maxProgramSize)
            throw new RegexException("pattern too large after expanding repetitions");
        code ~= Inst(op, a, b, c, d);
        return cast(int) code.length - 1;
    }

    int addSet(const CharSet s) @safe
    {
        ubyte[256] t;
        s.toTable(t);
        sets ~= t;
        return cast(int) sets.length - 1;
    }

    void gen(const Node n) @safe
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
            emit(Op.class_, addSet(n.set));
            break;
        case NodeKind.bol:
            emit(Op.bol);
            break;
        case NodeKind.eol:
            emit(Op.eol);
            break;
        case NodeKind.seq:
            foreach (c; n.children)
                gen(c);
            break;
        case NodeKind.alt:
            genAlt(n);
            break;
        case NodeKind.group:
            emit(Op.save, 2 * (n.group - 1));
            gen(n.children[0]);
            emit(Op.save, 2 * (n.group - 1) + 1);
            break;
        case NodeKind.repeat:
            genRepeat(n);
            break;
        }
    }

    void genAlt(const Node n) @safe
    {
        int[] jumps;
        foreach (i, branch; n.children)
        {
            if (i + 1 < n.children.length)
            {
                const sp = emit(Op.split, here() + 1);
                gen(branch);
                jumps ~= emit(Op.jmp);
                code[sp].b = here();
            }
            else
                gen(branch);
        }
        foreach (j; jumps)
            code[j].a = here();
    }

    void genRepeat(const Node n) @safe
    {
        const body_ = n.children[0];
        if (n.max == 0)
            return; // x{0} never runs x
        if (body_.isSingleChar)
        {
            final switch (body_.kind)
            {
            case NodeKind.literal:
                emit(Op.charLoop, LoopKind.char_, body_.ch, n.min, n.max);
                break;
            case NodeKind.any:
                emit(Op.charLoop, LoopKind.any, 0, n.min, n.max);
                break;
            case NodeKind.set:
                emit(Op.charLoop, LoopKind.class_, addSet(body_.set), n.min, n.max);
                break;
            case NodeKind.bol, NodeKind.eol, NodeKind.seq, NodeKind.alt,
                NodeKind.group, NodeKind.repeat:
                assert(0);
            }
            return;
        }

        const guarded = canBeEmpty(body_);
        foreach (_; 0 .. n.min)
            gen(body_);

        if (n.max < 0)
        {
            const loop = here();
            const sp = emit(Op.split, loop + 1);
            int reg, ck;
            if (guarded)
            {
                reg = nextSlot++;
                emit(Op.mark, reg);
            }
            gen(body_);
            if (guarded)
                ck = emit(Op.check, reg);
            emit(Op.jmp, loop);
            code[sp].b = here();
            if (guarded)
                code[ck].b = here();
        }
        else
        {
            int[] splits, checks;
            foreach (_; 0 .. n.max - n.min)
            {
                splits ~= emit(Op.split, here() + 1);
                int reg;
                if (guarded)
                {
                    reg = nextSlot++;
                    emit(Op.mark, reg);
                }
                gen(body_);
                if (guarded)
                    checks ~= emit(Op.check, reg);
            }
            foreach (s; splits)
                code[s].b = here();
            foreach (c; checks)
                code[c].b = here();
        }
    }
}

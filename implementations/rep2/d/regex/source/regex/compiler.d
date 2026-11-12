/**
 * Compiles a syntax tree into a $(MREF regex.program, Program).
 *
 * Counted repetitions are expanded: `x{n,m}` becomes `n` mandatory copies of
 * `x` followed by `m - n` nested optional copies (or a loop when unbounded).
 * Optional iterations that can match the empty string carry a
 * `mark`/`checkEmpty` pair implementing the rule that an empty optional
 * iteration ends the repetition.
 */
module regex.compiler;

import regex.ast;
import regex.charset;
import regex.exception;
import regex.parser;
import regex.program;

/// Upper bound on the size of a compiled program (guards against runaway expansion).
enum maxInstructions = 2_000_000;

/// Compiles an already parsed pattern.
Program compile(Parsed parsed) @safe
{
    auto c = Compiler();
    c.prog.groupCount = parsed.groupCount;
    c.nextSlot = c.prog.loopBase;
    c.emit(parsed.root);
    c.add(Op.accept);
    c.prog.slotCount = c.nextSlot;

    CharSet first;
    immutable nullable = parsed.root.collectFirst(first);
    c.prog.useFirstTable = !nullable;
    if (!nullable)
        first.toTable(c.prog.firstTable);
    c.prog.anchored = parsed.root.anchoredAtStart;
    return c.prog;
}

private struct Compiler
{
    Program prog;
    int nextSlot;

    int pc() const pure nothrow @safe
    {
        return cast(int) prog.code.length;
    }

    int add(Op op, int arg = 0, int arg2 = 0) @safe
    {
        if (prog.code.length >= maxInstructions)
            throw new RegexException("pattern too large");
        prog.code ~= Inst(op, arg, arg2);
        return pc - 1;
    }

    void emit(Node n) @safe
    {
        final switch (n.kind)
        {
        case NodeKind.literal:
            add(Op.literal, n.ch);
            break;
        case NodeKind.any:
            add(Op.any);
            break;
        case NodeKind.set:
            prog.sets ~= n.set;
            add(Op.set, cast(int) prog.sets.length - 1);
            break;
        case NodeKind.bol:
            add(Op.bol);
            break;
        case NodeKind.eol:
            add(Op.eol);
            break;
        case NodeKind.seq:
            foreach (c; n.children)
                emit(c);
            break;
        case NodeKind.alt:
            emitAlt(n);
            break;
        case NodeKind.group:
            add(Op.groupStart, n.group);
            emit(n.children[0]);
            add(Op.groupEnd, n.group);
            break;
        case NodeKind.repeat:
            emitRepeat(n);
            break;
        }
    }

    void emitAlt(Node n) @safe
    {
        int[] jumps;
        foreach (i, b; n.children)
        {
            if (i + 1 < n.children.length)
            {
                immutable split = add(Op.split);
                emit(b);
                jumps ~= add(Op.jump);
                prog.code[split].arg = pc;
            }
            else
                emit(b);
        }
        foreach (j; jumps)
            prog.code[j].arg = pc;
    }

    void emitRepeat(Node n) @safe
    {
        auto body_ = n.children[0];
        foreach (_; 0 .. n.min)
            emit(body_);

        immutable needCheck = body_.nullable;
        if (n.max == unbounded)
        {
            // L: split(body, END); [mark]; body; [checkEmpty -> END]; jump L; END:
            immutable loop = add(Op.split);
            immutable slot = needCheck ? nextSlot++ : -1;
            if (needCheck)
                add(Op.mark, slot);
            emit(body_);
            int check = -1;
            if (needCheck)
                check = add(Op.checkEmpty, slot);
            add(Op.jump, loop);
            prog.code[loop].arg = pc;
            if (needCheck)
                prog.code[check].arg2 = pc;
            return;
        }

        int[] exits; // split / checkEmpty instructions to patch to the end
        int[] checks;
        foreach (_; n.min .. n.max)
        {
            exits ~= add(Op.split);
            if (needCheck)
            {
                immutable slot = nextSlot++;
                add(Op.mark, slot);
                emit(body_);
                checks ~= add(Op.checkEmpty, slot);
            }
            else
                emit(body_);
        }
        foreach (e; exits)
            prog.code[e].arg = pc;
        foreach (e; checks)
            prog.code[e].arg2 = pc;
    }
}

/// Parses and compiles `pattern`.
Program compilePattern(const(char)[] pattern) @safe
{
    return compile(parse(pattern));
}

unittest
{
    auto p = compilePattern("a|b");
    assert(p.code[$ - 1].op == Op.accept);
    assert(p.groupCount == 0);
    assert(p.useFirstTable && p.firstTable['a'] && p.firstTable['b'] && !p.firstTable['c']);

    p = compilePattern("a*");
    assert(!p.useFirstTable);

    p = compilePattern("^(x)");
    assert(p.anchored && p.groupCount == 1);

    // {0} emits nothing for the body
    p = compilePattern("a{0}");
    assert(p.code.length == 1);

    // a non-nullable body needs no empty-iteration bookkeeping
    p = compilePattern("a{1,3}");
    foreach (i; p.code)
        assert(i.op != Op.mark && i.op != Op.checkEmpty);
    p = compilePattern("(a*)*");
    bool sawCheck;
    foreach (i; p.code)
        sawCheck |= i.op == Op.checkEmpty;
    assert(sawCheck);
}

/// Compiler from the syntax tree to a backtracking-VM program.
module btregex.program;

import btregex.ast;
import btregex.charset;

/// VM opcodes.
enum Op : ubyte
{
    /// Consume the character `ch`.
    char_,
    /// Consume any character.
    any,
    /// Consume a character that is a member of `sets[a]`.
    set,
    /// Succeed only at offset 0.
    bol,
    /// Succeed only at the end of the subject.
    eol,
    /// Continue at `a`; on failure resume at `b` at the current position.
    split,
    /// Continue at `a`.
    jmp,
    /// `regs[a] = position` (undone on backtracking).
    setReg,
    /// If the position equals `regs[a]` (an empty iteration) continue at
    /// `b`, otherwise fall through.
    chkEmpty,
    /// Complete group `a`: capture `(regs[b], position)`.
    groupEnd,
    /// Overall success.
    match,
}

/// One VM instruction.
struct Inst
{
    Op op;
    ubyte ch;
    int a;
    int b;
}

/// A compiled pattern.
struct Program
{
    Inst[] code;
    CharSet[] sets;
    /// Number of capturing groups; registers `0 .. 2*groups` hold the
    /// capture offsets (start, end per group, -1 when unset).
    int groups;
    /// Total register count (captures, group-entry temporaries, loop marks).
    int regCount;
}

/// Compiles a syntax tree with `groups` capturing groups.
///
/// Counted repeats are expanded: `x{n,m}` becomes `n` mandatory copies of
/// `x` followed by `m-n` nested optional copies (or a loop when unbounded).
/// Each optional iteration remembers where it started so that an iteration
/// matching the empty string ends the repetition, as section 3 requires.
Program compile(Node root, int groups) @safe
{
    auto c = Compiler(groups);
    c.emit(root);
    c.put(Op.match);
    Program p;
    p.code = c.code;
    p.sets = c.sets;
    p.groups = groups;
    p.regCount = c.nextReg;
    return p;
}

private struct Compiler
{
    Inst[] code;
    CharSet[] sets;
    int groups;
    int nextReg;

    this(int groups) pure nothrow @safe
    {
        this.groups = groups;
        // capture registers, then one entry register per group
        nextReg = 3 * groups;
    }

    int here() const pure nothrow @nogc @safe
    {
        return cast(int) code.length;
    }

    int put(Op op, int a = 0, int b = 0, ubyte ch = 0) pure nothrow @safe
    {
        code ~= Inst(op, ch, a, b);
        return here - 1;
    }

    void emit(Node n) @safe
    {
        final switch (n.kind)
        {
        case NodeKind.literal:
            put(Op.char_, 0, 0, n.ch);
            break;
        case NodeKind.any:
            put(Op.any);
            break;
        case NodeKind.set:
            sets ~= n.set;
            put(Op.set, cast(int) sets.length - 1);
            break;
        case NodeKind.bol:
            put(Op.bol);
            break;
        case NodeKind.eol:
            put(Op.eol);
            break;
        case NodeKind.seq:
            foreach (k; n.kids)
                emit(k);
            break;
        case NodeKind.alt:
            emitAlt(n);
            break;
        case NodeKind.group:
            {
                const entry = 2 * groups + n.group - 1;
                put(Op.setReg, entry);
                emit(n.kids[0]);
                put(Op.groupEnd, n.group, entry);
                break;
            }
        case NodeKind.repeat:
            emitRepeat(n);
            break;
        }
    }

    void emitAlt(Node n) @safe
    {
        int[] jumps;
        foreach (i, k; n.kids)
        {
            if (i + 1 < n.kids.length)
            {
                const sp = put(Op.split);
                code[sp].a = here;
                emit(k);
                jumps ~= put(Op.jmp);
                code[sp].b = here;
            }
            else
                emit(k);
        }
        foreach (j; jumps)
            code[j].a = here;
    }

    void emitRepeat(Node n) @safe
    {
        auto body_ = n.kids[0];
        foreach (_; 0 .. n.min)
            emit(body_);
        // A single-character body always consumes, so it needs no empty check.
        const needCheck = !body_.isSingleChar;
        if (n.max == unbounded)
        {
            const loop = put(Op.split);
            code[loop].a = here;
            const reg = needCheck ? nextReg++ : -1;
            if (needCheck)
                put(Op.setReg, reg);
            emit(body_);
            int chk = -1;
            if (needCheck)
                chk = put(Op.chkEmpty, reg);
            put(Op.jmp, loop);
            code[loop].b = here;
            if (needCheck)
                code[chk].b = here;
            return;
        }
        int[] splits, checks;
        foreach (_; n.min .. n.max)
        {
            splits ~= put(Op.split);
            code[splits[$ - 1]].a = here;
            if (needCheck)
            {
                const reg = nextReg++;
                put(Op.setReg, reg);
                emit(body_);
                checks ~= put(Op.chkEmpty, reg);
            }
            else
                emit(body_);
        }
        foreach (s; splits)
            code[s].b = here;
        foreach (c; checks)
            code[c].b = here;
    }
}

unittest
{
    import btregex.parser : parse;

    auto r = parse("a|b");
    auto p = compile(r.root, r.groupCount);
    assert(p.code[$ - 1].op == Op.match);
    assert(p.code[0].op == Op.split);

    auto q = parse("(x){2,4}");
    auto pq = compile(q.root, q.groupCount);
    // 2 mandatory + 2 optional copies of the group
    size_t ends;
    foreach (i; pq.code)
        if (i.op == Op.groupEnd)
            ends++;
    assert(ends == 4);
}

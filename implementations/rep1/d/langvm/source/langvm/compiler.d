/// The bytecode compiler: checked syntax tree -> `Program` (SPEC.md section 16).
module langvm.compiler;

import langvm.ast;
import langvm.bytecode;
import langvm.symbols;
import langvm.types;
import langvm.value;

/// Compile all checked function bodies into a runnable program.
Program compileProgram(World w, FnInfo[] bodies)
{
    auto c = new Compiler(w);
    return c.compile(bodies);
}

private struct Loop
{
    /// Operand-stack depth at the start of the loop.
    int depth;
    int[] breaks;
    int[] continues;
    /// Known target for `continue`, or -1 when it must be patched.
    int continueTarget;
}

/// Per-function compilation state.
private final class FnState
{
    Func func;
    FuncCtx ctx;
    Instr[] code;
    int nextSlot;
    int maxSlot;
    int depth;
    Loop[] loops;
}

private final class Compiler
{
    World w;
    Program prog;
    FnState cur;
    size_t[long] intConsts;
    size_t[ulong] floatConsts;
    size_t[long] charConsts;
    size_t[dstring] strConsts;
    size_t[int] unitVariantConsts;

    this(World w)
    {
        this.w = w;
        prog = new Program();
    }

    Program compile(FnInfo[] bodies)
    {
        // Reserve one function slot per body so calls can refer to callees by index.
        foreach (fi; bodies)
        {
            fi.funcIdx = cast(int) prog.funcs.length;
            auto f = new Func();
            f.name = fi.name;
            prog.funcs ~= f;
        }
        foreach (fi; bodies)
            compileBody(fi);

        // the entry stub
        auto stub = new Func();
        stub.name = "<entry>";
        stub.counted = false;
        stub.code = [Instr(Op.call, w.mainFn.funcIdx, 0), Instr(Op.halt)];
        prog.entry = cast(int) prog.funcs.length;
        prog.funcs ~= stub;

        buildImplTable();
        prog.optionDecl = w.optionDecl.id;
        prog.resultDecl = w.resultDecl.id;
        return prog;
    }

    void buildImplTable()
    {
        const nctors = Ctor.firstDecl + cast(int) w.decls.length;
        prog.impls = new int[][][w.traits.length];
        foreach (im; w.impls)
        {
            auto tr = im.trait;
            if (prog.impls[tr.id] is null)
                prog.impls[tr.id] = new int[][nctors];
            int[] fns;
            foreach (i, sig; tr.methods)
            {
                auto fi = im.methods[i] !is null ? im.methods[i] : sig.defaultFn;
                fns ~= fi.funcIdx;
            }
            prog.impls[tr.id][im.ctor] = fns;
        }
    }

    // ------------------------------------------------------------ emission helpers

    static int effect(Instr i)
    {
        final switch (i.op)
        {
        case Op.pushConst, Op.pushTrue, Op.pushFalse, Op.pushUnit, Op.loadLocal, Op.loadUpval, Op.dup:
            return 1;
        case Op.storeLocal, Op.pop:
            return -1;
        case Op.makeClosure:
            return 1 - i.b;
        case Op.call, Op.callBuiltin:
            return 1 - i.b;
        case Op.callValue:
            return -i.a;
        case Op.callMethod:
            return -i.c;
        case Op.ret:
            return -1;
        case Op.retUnit:
            return 0;
        case Op.addI, Op.subI, Op.mulI, Op.divI, Op.modI, Op.band, Op.bor, Op.bxor, Op.shl, Op.shr,
            Op.addF, Op.subF, Op.mulF, Op.divF, Op.eq, Op.ne, Op.lt, Op.le, Op.gt, Op.ge,
            Op.concatStr, Op.concatList:
            return -1;
        case Op.negI, Op.bnot, Op.negF, Op.notB:
            return 0;
        case Op.jump:
            return 0;
        case Op.jumpIfFalse, Op.jumpIfTrue:
            return -1;
        case Op.makeList, Op.makeTuple:
            return 1 - i.a;
        case Op.makeMap:
            return 1 - 2 * i.a;
        case Op.makeStruct:
            return 1 - i.b;
        case Op.makeEnum:
            return 1 - i.c;
        case Op.getField, Op.getPayload, Op.getTuple, Op.isVariant, Op.seqLen, Op.listRest:
            return 0;
        case Op.indexGet:
            return -1;
        case Op.indexSet:
            return -3;
        case Op.noMatch, Op.halt:
            return 0;
        case Op.panic:
            return -1;
        }
    }

    int emit(Op op, int a = 0, int b = 0, int c = 0)
    {
        auto i = Instr(op, a, b, c);
        cur.depth += effect(i);
        cur.code ~= i;
        return cast(int) cur.code.length - 1;
    }

    int here()
    {
        return cast(int) cur.code.length;
    }

    void patch(int at)
    {
        cur.code[at].a = here();
    }

    void patchAll(int[] ats)
    {
        foreach (a; ats)
            patch(a);
    }

    int allocSlot()
    {
        const s = cur.nextSlot++;
        if (cur.nextSlot > cur.maxSlot)
            cur.maxSlot = cur.nextSlot;
        return s;
    }

    // ------------------------------------------------------------ constants

    int constant(Value v)
    {
        prog.consts ~= v;
        return cast(int) prog.consts.length - 1;
    }

    int intConst(long v)
    {
        if (auto p = v in intConsts)
            return cast(int)*p;
        const i = constant(Value.ofInt(v));
        intConsts[v] = i;
        return i;
    }

    int floatConst(double v)
    {
        const bits = *cast(ulong*)&v;
        if (auto p = bits in floatConsts)
            return cast(int)*p;
        const i = constant(Value.ofFloat(v));
        floatConsts[bits] = i;
        return i;
    }

    int charConst(long v)
    {
        if (auto p = v in charConsts)
            return cast(int)*p;
        const i = constant(Value.ofChar(v));
        charConsts[v] = i;
        return i;
    }

    int strConst(dstring v)
    {
        if (auto p = v in strConsts)
            return cast(int)*p;
        const i = constant(Value.ofStr(v));
        strConsts[v] = i;
        return i;
    }

    /// Constant for a variant without payload (the value is immutable, so it is shared).
    int unitVariantConst(VariantInfo v)
    {
        const key = v.decl.id * 4096 + v.index;
        if (auto p = key in unitVariantConsts)
            return cast(int)*p;
        const i = constant(Value.ofObj(Tag.enum_, new AggObj(v.decl.id, v.index, null)));
        unitVariantConsts[key] = i;
        return i;
    }

    // ------------------------------------------------------------ functions

    void compileBody(FnInfo fi)
    {
        auto decl = fi.decl;
        auto f = prog.funcs[fi.funcIdx];
        auto st = new FnState();
        st.func = f;
        st.ctx = decl.ctx;
        auto saved = cur;
        cur = st;
        foreach (v; decl.paramVars)
            v.slot = allocSlot();
        f.nparams = cast(int) decl.paramVars.length;
        block(decl.body);
        emit(Op.ret);
        finish(st);
        cur = saved;
    }

    void finish(FnState st)
    {
        st.func.code = st.code;
        st.func.nlocals = st.maxSlot;
    }

    void compileLambda(LambdaExpr e)
    {
        auto f = new Func();
        f.name = "<lambda>";
        const idx = cast(int) prog.funcs.length;
        prog.funcs ~= f;
        auto st = new FnState();
        st.func = f;
        st.ctx = e.ctx;
        auto saved = cur;
        cur = st;
        foreach (v; e.paramVars)
            v.slot = allocSlot();
        f.nparams = cast(int) e.paramVars.length;
        if (e.body.kind == EK.block)
            block(cast(BlockExpr) e.body);
        else
            expr(e.body);
        emit(Op.ret);
        finish(st);
        cur = saved;
        foreach (v; e.ctx.captures)
            loadVar(v);
        emit(Op.makeClosure, idx, cast(int) e.ctx.captures.length);
    }

    void loadVar(LocalVar v)
    {
        if (v.owner is cur.ctx)
            emit(Op.loadLocal, v.slot);
        else
        {
            const i = cur.ctx.captureIndex(v);
            assert(i >= 0, "captured variable missing from the closure");
            emit(Op.loadUpval, i);
        }
    }

    // ------------------------------------------------------------ blocks and statements

    /// Compile a block so that it leaves exactly one value on the stack.
    void block(BlockExpr b)
    {
        const mark = cur.nextSlot;
        const d0 = cur.depth;
        foreach (s; b.stmts)
            stmt(s);
        if (b.tail !is null)
            expr(b.tail);
        else
            emit(Op.pushUnit);
        cur.nextSlot = mark;
        cur.depth = d0 + 1;
    }

    /// A loop body: statements, then the trailing expression (if any) is evaluated and dropped.
    void stmtBlock(BlockExpr b)
    {
        const mark = cur.nextSlot;
        const d0 = cur.depth;
        foreach (s; b.stmts)
            stmt(s);
        if (b.tail !is null)
        {
            expr(b.tail);
            emit(Op.pop);
        }
        cur.nextSlot = mark;
        cur.depth = d0;
    }

    void stmt(Stmt s)
    {
        const d0 = cur.depth;
        final switch (s.kind)
        {
        case SK.let_:
            expr(s.expr);
            bindPattern(s.pat);
            break;
        case SK.var_:
            expr(s.expr);
            s.var.slot = allocSlot();
            emit(Op.storeLocal, s.var.slot);
            break;
        case SK.assign:
            if (s.target.kind == EK.index)
            {
                auto ix = cast(IndexExpr) s.target;
                expr(ix.obj);
                expr(ix.idx);
                expr(s.expr);
                emit(Op.indexSet);
            }
            else
            {
                expr(s.expr);
                emit(Op.storeLocal, s.var.slot);
            }
            break;
        case SK.expr:
            expr(s.expr);
            emit(Op.pop);
            break;
        case SK.while_:
            whileLoop(s);
            break;
        case SK.for_:
            forLoop(s);
            break;
        case SK.return_:
            if (s.expr is null)
                emit(Op.retUnit);
            else
            {
                expr(s.expr);
                emit(Op.ret);
            }
            break;
        case SK.break_:
        {
            auto lp = &cur.loops[$ - 1];
            foreach (_; 0 .. cur.depth - lp.depth)
                emit(Op.pop);
            lp.breaks ~= emit(Op.jump);
            break;
        }
        case SK.continue_:
        {
            auto lp = &cur.loops[$ - 1];
            foreach (_; 0 .. cur.depth - lp.depth)
                emit(Op.pop);
            if (lp.continueTarget >= 0)
                emit(Op.jump, lp.continueTarget);
            else
                lp.continues ~= emit(Op.jump);
            break;
        }
        }
        cur.depth = d0;
    }

    /// The value on top of the stack is destructured by `p` (which must be irrefutable).
    void bindPattern(Pattern p)
    {
        if (p.kind == PatK.wild)
        {
            emit(Op.pop);
            return;
        }
        if (p.kind == PatK.bind)
        {
            p.var.slot = allocSlot();
            emit(Op.storeLocal, p.var.slot);
            return;
        }
        const tmp = allocSlot();
        emit(Op.storeLocal, tmp);
        int[] fails;
        pattern(p, tmp, fails);
        if (fails.length)
        {
            const skip = emit(Op.jump);
            patchAll(fails);
            emit(Op.noMatch);
            patch(skip);
        }
    }

    void whileLoop(Stmt s)
    {
        const mark = cur.nextSlot;
        const start = here();
        expr(s.expr);
        const exitJump = emit(Op.jumpIfFalse);
        cur.loops ~= Loop(cur.depth, null, null, start);
        stmtBlock(s.body);
        emit(Op.jump, start);
        patch(exitJump);
        auto lp = cur.loops[$ - 1];
        cur.loops.length = cur.loops.length - 1;
        patchAll(lp.breaks);
        cur.nextSlot = mark;
    }

    void forLoop(Stmt s)
    {
        const mark = cur.nextSlot;
        const seq = allocSlot();
        const idx = allocSlot();
        int hi = -1;
        if (s.forKind == 2)
        {
            hi = allocSlot();
            expr(s.expr);
            emit(Op.storeLocal, idx);
            expr(s.hi);
            emit(Op.storeLocal, hi);
        }
        else
        {
            expr(s.expr);
            emit(Op.storeLocal, seq);
            emit(Op.pushConst, intConst(0));
            emit(Op.storeLocal, idx);
        }
        const start = here();
        emit(Op.loadLocal, idx);
        if (s.forKind == 2)
            emit(Op.loadLocal, hi);
        else
        {
            emit(Op.loadLocal, seq);
            emit(Op.seqLen);
        }
        emit(Op.lt);
        const exitJump = emit(Op.jumpIfFalse);
        cur.loops ~= Loop(cur.depth, null, null, -1);
        const inner = cur.nextSlot;
        if (s.forKind == 2)
            emit(Op.loadLocal, idx);
        else
        {
            emit(Op.loadLocal, seq);
            emit(Op.loadLocal, idx);
            emit(Op.indexGet);
        }
        bindPattern(s.pat);
        stmtBlock(s.body);
        cur.nextSlot = inner;
        auto lp = cur.loops[$ - 1];
        cur.loops.length = cur.loops.length - 1;
        patchAll(lp.continues);
        emit(Op.loadLocal, idx);
        emit(Op.pushConst, intConst(1));
        emit(Op.addI);
        emit(Op.storeLocal, idx);
        emit(Op.jump, start);
        patch(exitJump);
        patchAll(lp.breaks);
        cur.nextSlot = mark;
    }

    // ------------------------------------------------------------ patterns

    /// Test the value in local `slot` against `p`, binding variables. On a
    /// failed test control jumps to a location recorded in `fails`.
    void pattern(Pattern p, int slot, ref int[] fails)
    {
        final switch (p.kind)
        {
        case PatK.wild:
            return;
        case PatK.bind:
            p.var.slot = slot;
            return;
        case PatK.float_:
            assert(false);
        case PatK.int_:
            emit(Op.loadLocal, slot);
            emit(Op.pushConst, intConst(p.ival));
            emit(Op.eq);
            fails ~= emit(Op.jumpIfFalse);
            return;
        case PatK.char_:
            emit(Op.loadLocal, slot);
            emit(Op.pushConst, charConst(p.ival));
            emit(Op.eq);
            fails ~= emit(Op.jumpIfFalse);
            return;
        case PatK.str:
            emit(Op.loadLocal, slot);
            emit(Op.pushConst, strConst(p.sval));
            emit(Op.eq);
            fails ~= emit(Op.jumpIfFalse);
            return;
        case PatK.bool_:
            emit(Op.loadLocal, slot);
            fails ~= emit(p.ival ? Op.jumpIfFalse : Op.jumpIfTrue);
            return;
        case PatK.tuple:
            foreach (i, sp; p.subs)
                subPattern(sp, slot, Op.getTuple, cast(int) i, fails);
            return;
        case PatK.variant:
            if (p.variant.decl.variants.length > 1)
            {
                emit(Op.loadLocal, slot);
                emit(Op.isVariant, p.variant.index);
                fails ~= emit(Op.jumpIfFalse);
            }
            foreach (i, sp; p.subs)
                subPattern(sp, slot, Op.getPayload, cast(int) i, fails);
            return;
        case PatK.struct_:
            foreach (ref f; p.fields)
            {
                if (f.pat !is null)
                    subPattern(f.pat, slot, Op.getField, f.fieldIdx, fails);
                else
                {
                    f.var.slot = allocSlot();
                    emit(Op.loadLocal, slot);
                    emit(Op.getField, f.fieldIdx);
                    emit(Op.storeLocal, f.var.slot);
                }
            }
            return;
        case PatK.list:
        {
            const n = cast(int) p.subs.length;
            if (!(p.hasRest && n == 0))
            {
                emit(Op.loadLocal, slot);
                emit(Op.seqLen);
                emit(Op.pushConst, intConst(n));
                emit(p.hasRest ? Op.ge : Op.eq);
                fails ~= emit(Op.jumpIfFalse);
            }
            foreach (i, sp; p.subs)
            {
                if (sp.kind == PatK.wild)
                    continue;
                const t = allocSlot();
                emit(Op.loadLocal, slot);
                emit(Op.pushConst, intConst(cast(long) i));
                emit(Op.indexGet);
                emit(Op.storeLocal, t);
                pattern(sp, t, fails);
            }
            if (p.restVar !is null)
            {
                p.restVar.slot = allocSlot();
                emit(Op.loadLocal, slot);
                emit(Op.listRest, n);
                emit(Op.storeLocal, p.restVar.slot);
            }
            return;
        }
        }
    }

    void subPattern(Pattern sp, int slot, Op getter, int index, ref int[] fails)
    {
        if (sp.kind == PatK.wild)
            return;
        const t = allocSlot();
        emit(Op.loadLocal, slot);
        emit(getter, index);
        emit(Op.storeLocal, t);
        pattern(sp, t, fails);
    }

    // ------------------------------------------------------------ expressions

    /// Compile an expression so that it leaves exactly one value on the stack.
    void expr(Expr e)
    {
        const d0 = cur.depth;
        exprInner(e);
        cur.depth = d0 + 1;
    }

    void exprs(Expr[] es)
    {
        foreach (x; es)
            expr(x);
    }

    void exprInner(Expr e)
    {
        final switch (e.kind)
        {
        case EK.int_:
            emit(Op.pushConst, intConst((cast(LitExpr) e).ival));
            return;
        case EK.float_:
            emit(Op.pushConst, floatConst((cast(LitExpr) e).fval));
            return;
        case EK.str:
            emit(Op.pushConst, strConst((cast(LitExpr) e).sval));
            return;
        case EK.char_:
            emit(Op.pushConst, charConst((cast(LitExpr) e).ival));
            return;
        case EK.bool_:
            emit((cast(LitExpr) e).ival ? Op.pushTrue : Op.pushFalse);
            return;
        case EK.self_:
            loadVar((cast(SelfExpr) e).var);
            return;
        case EK.path:
        {
            auto p = cast(PathExpr) e;
            if (p.res == ResK.local)
                loadVar(p.var);
            else
                emit(Op.pushConst, unitVariantConst(p.variant));
            return;
        }
        case EK.structLit:
            structLit(cast(StructLitExpr) e);
            return;
        case EK.tuple:
        {
            auto s = cast(SeqExpr) e;
            exprs(s.elems);
            emit(Op.makeTuple, cast(int) s.elems.length);
            return;
        }
        case EK.list:
        {
            auto s = cast(SeqExpr) e;
            exprs(s.elems);
            emit(Op.makeList, cast(int) s.elems.length);
            return;
        }
        case EK.map:
        {
            auto s = cast(SeqExpr) e;
            exprs(s.elems);
            emit(Op.makeMap, cast(int) s.elems.length / 2);
            return;
        }
        case EK.lambda:
            compileLambda(cast(LambdaExpr) e);
            return;
        case EK.if_:
            ifExpr(cast(IfExpr) e);
            return;
        case EK.match:
            matchExpr(cast(MatchExpr) e);
            return;
        case EK.block:
            block(cast(BlockExpr) e);
            return;
        case EK.unary:
        {
            auto u = cast(UnaryExpr) e;
            expr(u.operand);
            switch (u.op)
            {
            case Operator.neg:
                emit(u.isFloat ? Op.negF : Op.negI);
                break;
            case Operator.not:
                emit(Op.notB);
                break;
            default:
                emit(Op.bnot);
                break;
            }
            return;
        }
        case EK.binary:
            binary(cast(BinaryExpr) e);
            return;
        case EK.call:
            call(cast(CallExpr) e);
            return;
        case EK.method:
        {
            auto m = cast(MethodExpr) e;
            expr(m.recv);
            exprs(m.args);
            emit(Op.callMethod, m.trait.id, m.methodIdx, cast(int) m.args.length);
            return;
        }
        case EK.index:
        {
            auto ix = cast(IndexExpr) e;
            expr(ix.obj);
            expr(ix.idx);
            emit(Op.indexGet);
            return;
        }
        case EK.field:
        {
            auto f = cast(FieldExpr) e;
            expr(f.obj);
            emit(Op.getField, f.fieldIdx);
            return;
        }
        }
    }

    void structLit(StructLitExpr s)
    {
        const n = cast(int) s.decl.fields.length;
        bool inOrder = true;
        foreach (i, f; s.fieldOf)
            inOrder &= f == cast(int) i;
        if (inOrder)
        {
            foreach (init; s.inits)
                expr(init.value);
        }
        else
        {
            const mark = cur.nextSlot;
            int[] slots;
            foreach (init; s.inits)
            {
                expr(init.value);
                const t = allocSlot();
                emit(Op.storeLocal, t);
                slots ~= t;
            }
            foreach (fi; 0 .. n)
                foreach (i, f; s.fieldOf)
                    if (f == fi)
                        emit(Op.loadLocal, slots[i]);
            cur.nextSlot = mark;
        }
        emit(Op.makeStruct, s.decl.id, n);
    }

    void ifExpr(IfExpr e)
    {
        expr(e.cond);
        const d0 = cur.depth;
        const elseJump = emit(Op.jumpIfFalse);
        block(e.then);
        const endJump = emit(Op.jump);
        patch(elseJump);
        cur.depth = d0;
        if (e.else_ !is null)
            expr(e.else_);
        else
            emit(Op.pushUnit);
        patch(endJump);
    }

    void matchExpr(MatchExpr e)
    {
        const d0 = cur.depth;
        const mark = cur.nextSlot;
        expr(e.scrut);
        const s = allocSlot();
        emit(Op.storeLocal, s);
        int[] ends;
        foreach (ref a; e.arms)
        {
            cur.depth = d0;
            const armMark = cur.nextSlot;
            int[] fails;
            pattern(a.pat, s, fails);
            if (a.guard !is null)
            {
                expr(a.guard);
                fails ~= emit(Op.jumpIfFalse);
            }
            expr(a.body);
            ends ~= emit(Op.jump);
            patchAll(fails);
            cur.nextSlot = armMark;
        }
        cur.depth = d0;
        emit(Op.noMatch);
        patchAll(ends);
        cur.nextSlot = mark;
    }

    void binary(BinaryExpr e)
    {
        final switch (e.op)
        {
        case Operator.and:
        {
            expr(e.left);
            const d0 = cur.depth;
            const j = emit(Op.jumpIfFalse);
            expr(e.right);
            const end = emit(Op.jump);
            patch(j);
            cur.depth = d0;
            emit(Op.pushFalse);
            patch(end);
            return;
        }
        case Operator.or:
        {
            expr(e.left);
            const d0 = cur.depth;
            const j = emit(Op.jumpIfTrue);
            expr(e.right);
            const end = emit(Op.jump);
            patch(j);
            cur.depth = d0;
            emit(Op.pushTrue);
            patch(end);
            return;
        }
        case Operator.neg, Operator.not, Operator.bnot:
            assert(false);
        case Operator.add, Operator.sub, Operator.mul, Operator.div,
            Operator.rem, Operator.concat, Operator.band, Operator.bor,
            Operator.bxor, Operator.shl, Operator.shr, Operator.lt,
            Operator.le, Operator.gt, Operator.ge, Operator.eq, Operator.ne:
            break;
        }
        expr(e.left);
        expr(e.right);
        Op op;
        final switch (e.op)
        {
        case Operator.add: op = e.isFloat ? Op.addF : Op.addI; break;
        case Operator.sub: op = e.isFloat ? Op.subF : Op.subI; break;
        case Operator.mul: op = e.isFloat ? Op.mulF : Op.mulI; break;
        case Operator.div: op = e.isFloat ? Op.divF : Op.divI; break;
        case Operator.rem: op = Op.modI; break;
        case Operator.concat: op = e.isStr ? Op.concatStr : Op.concatList; break;
        case Operator.band: op = Op.band; break;
        case Operator.bor: op = Op.bor; break;
        case Operator.bxor: op = Op.bxor; break;
        case Operator.shl: op = Op.shl; break;
        case Operator.shr: op = Op.shr; break;
        case Operator.lt: op = Op.lt; break;
        case Operator.le: op = Op.le; break;
        case Operator.gt: op = Op.gt; break;
        case Operator.ge: op = Op.ge; break;
        case Operator.eq: op = Op.eq; break;
        case Operator.ne: op = Op.ne; break;
        case Operator.neg, Operator.not, Operator.bnot, Operator.and, Operator.or:
            assert(false);
        }
        emit(op);
    }

    void call(CallExpr e)
    {
        final switch (e.ck)
        {
        case CallK.none:
            assert(false);
        case CallK.direct:
            exprs(e.args);
            emit(Op.call, e.fn.funcIdx, cast(int) e.args.length);
            return;
        case CallK.builtin:
            exprs(e.args);
            emit(Op.callBuiltin, e.fn.builtinId, cast(int) e.args.length);
            return;
        case CallK.variant:
            exprs(e.args);
            emit(Op.makeEnum, e.variant.decl.id, e.variant.index, cast(int) e.args.length);
            return;
        case CallK.trait:
            exprs(e.args);
            emit(Op.callMethod, e.trait.id, e.methodIdx, cast(int) e.args.length - 1);
            return;
        case CallK.indirect:
            expr(e.callee);
            exprs(e.args);
            emit(Op.callValue, cast(int) e.args.length);
            return;
        }
    }
}

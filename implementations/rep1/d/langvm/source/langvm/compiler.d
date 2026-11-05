/// Bytecode compiler: translates the checked AST into flat bytecode.
module langvm.compiler;

import langvm.ast;
import langvm.bytecode;
import langvm.lexer : Tk;
import langvm.model;
import langvm.value;
import langvm.world;

private final class LoopCtx
{
    int depth;
    int[] breaks;
    int[] continues;
    /// Known continue target (while loops), or -1 when patched later.
    int contTarget = -1;
}

private final class FnState
{
    FuncInfo info;
    int[] code;
    int depth;
    int maxDepth;
    int nextSlot;
    int maxSlot;
    LoopCtx[] loops;
}

/// Compiles a checked [World] into a [Program].
final class Compiler
{
    private World w;
    private Program prog;
    private FnState cur;
    private int[long] intK;
    private int[ulong] floatK;
    private int[long] charK;
    private int[dstring] strK;

    this(World w)
    {
        this.w = w;
    }

    /// Compiles every function of the program.
    Program compile()
    {
        prog = new Program;
        foreach (i, fd; w.funcs)
        {
            fd.index = cast(int) i;
            auto fc = new FuncCode;
            fc.name = fd.name;
            prog.funcs ~= fc;
        }
        foreach (fd; w.funcs)
            compileFunc(fd);
        prog.mainFn = w.mainFn.index;
        prog.declCount = cast(int) w.datas.length;
        buildMethodTable();
        buildUnitVariants();
        return prog;
    }

    private void buildMethodTable()
    {
        int nctor = HeadCtor.firstData + cast(int) w.datas.length;
        prog.methodTable = new int[][][w.traits.length];
        foreach (t; w.traits)
            prog.methodTable[t.id] = new int[][nctor];
        foreach (im; w.impls)
        {
            auto tr = im.trait;
            int[] row = new int[tr.methods.length];
            foreach (i, md; tr.methods)
            {
                auto f = im.byIndex[i];
                if (f !is null)
                    row[i] = f.index;
                else if (md.defaultFn !is null)
                    row[i] = md.defaultFn.index;
                else
                    row[i] = -1;
            }
            prog.methodTable[tr.id][im.headCtor] = row;
        }
    }

    private void buildUnitVariants()
    {
        prog.unitVariants = new Value[][w.datas.length];
        foreach (d; w.datas)
        {
            if (!d.isEnum)
                continue;
            auto row = new Value[d.variants.length];
            foreach (i, v; d.variants)
                if (v.payload.length == 0)
                    row[i] = Value.obj(VT.enum_, new AggObj(d.id, cast(int) i, null));
            prog.unitVariants[d.id] = row;
        }
    }

    // ------------------------------------------------------------ emission

    private int stackDelta(Op op, int a, int b, int c)
    {
        final switch (op)
        {
        case Op.pushConst, Op.pushTrue, Op.pushFalse, Op.pushUnit, Op.loadLocal, Op.loadUpval,
            Op.dup, Op.pushPayload, Op.pushField, Op.pushTuple, Op.pushElem, Op.listRest,
            Op.seqLen, Op.seqGet:
            return 1;
        case Op.storeLocal, Op.pop, Op.jumpIfFalse, Op.jumpIfTrue:
            return -1;
        case Op.makeClosure, Op.call, Op.callBuiltin, Op.makeTuple, Op.makeList:
            return op == Op.makeList || op == Op.makeTuple ? 1 - a : 1 - b;
        case Op.callValue:
            return -a;
        case Op.callMethod:
            return -c;
        case Op.ret:
            return -1;
        case Op.retUnit, Op.negI, Op.bnot, Op.negF, Op.notB, Op.jump, Op.getField, Op.getPayload,
            Op.getTuple, Op.noMatch, Op.jumpUnlessVariant, Op.jumpUnlessLen, Op.jumpUnlessLenGe,
            Op.incLocal:
            return 0;
        case Op.addI, Op.subI, Op.mulI, Op.divI, Op.modI, Op.band, Op.bor, Op.bxor, Op.shl, Op.shr,
            Op.addF, Op.subF, Op.mulF, Op.divF, Op.eq, Op.ne, Op.lt, Op.le, Op.gt, Op.ge,
            Op.concatStr, Op.concatList, Op.indexGet:
            return -1;
        case Op.indexSet:
            return -3;
        case Op.makeMap:
            return 1 - 2 * a;
        case Op.makeStruct:
            return 1 - b;
        case Op.makeEnum:
            return 1 - c;
        }
    }

    private void emit(Op op, int a = 0, int b = 0, int c = 0)
    {
        int n = operandCount(op);
        cur.code ~= cast(int) op;
        if (n >= 1)
            cur.code ~= a;
        if (n >= 2)
            cur.code ~= b;
        if (n >= 3)
            cur.code ~= c;
        cur.depth += stackDelta(op, a, b, c);
        if (cur.depth > cur.maxDepth)
            cur.maxDepth = cur.depth;
    }

    private int here()
    {
        return cast(int) cur.code.length;
    }

    /// Emits a jump with a placeholder target; returns the index of the target operand.
    private int emitJump(Op op)
    {
        emit(op, -1);
        return here() - 1;
    }

    /// Emits a fused test jump; returns the index of its target operand.
    private int emitTest(Op op, int a, int b)
    {
        emit(op, a, b, -1);
        return here() - 1;
    }

    private void patch(int at)
    {
        cur.code[at] = here();
    }

    private void patchAll(int[] list)
    {
        foreach (p; list)
            patch(p);
    }

    private int allocSlot()
    {
        int s = cur.nextSlot++;
        if (cur.nextSlot > cur.maxSlot)
            cur.maxSlot = cur.nextSlot;
        return s;
    }

    private int constInt(long v)
    {
        if (auto p = v in intK)
            return *p;
        prog.consts ~= Value.int_(v);
        return intK[v] = cast(int) prog.consts.length - 1;
    }

    private int constFloat(double v)
    {
        ulong bits = *cast(ulong*)&v;
        if (auto p = bits in floatK)
            return *p;
        prog.consts ~= Value.float_(v);
        return floatK[bits] = cast(int) prog.consts.length - 1;
    }

    private int constChar(dchar v)
    {
        if (auto p = cast(long) v in charK)
            return *p;
        prog.consts ~= Value.char_(v);
        return charK[v] = cast(int) prog.consts.length - 1;
    }

    private int constStr(dstring v)
    {
        if (auto p = v in strK)
            return *p;
        prog.consts ~= Value.str(v);
        return strK[v] = cast(int) prog.consts.length - 1;
    }

    // ------------------------------------------------------------ functions

    private void finishFn(FuncCode fc, FnState st, int nparams)
    {
        fc.nparams = nparams;
        fc.nslots = st.maxSlot;
        fc.maxStack = st.maxDepth;
        fc.code = st.code;
    }

    private void compileFunc(FuncDecl fd)
    {
        auto st = new FnState;
        st.info = fd.info;
        cur = st;
        int np = 0;
        if (fd.selfVar !is null)
        {
            fd.selfVar.slot = allocSlot();
            np++;
        }
        foreach (v; fd.paramVars)
        {
            v.slot = allocSlot();
            np++;
        }
        compileBody(fd.body);
        finishFn(prog.funcs[fd.index], st, np);
    }

    private void compileBody(Expr body_)
    {
        if (auto b = cast(Block) body_)
        {
            foreach (s; b.stmts)
                stmt(s);
            if (b.trailing !is null)
            {
                expr(b.trailing);
                emit(Op.ret);
            }
            else
                emit(Op.retUnit);
        }
        else
        {
            expr(body_);
            emit(Op.ret);
        }
    }

    // ------------------------------------------------------------ statements

    private void stmt(Stmt s)
    {
        if (auto l = cast(LetStmt) s)
        {
            expr(l.init);
            bindFromStack(l.pat);
        }
        else if (auto v = cast(VarStmt) s)
        {
            expr(v.init);
            v.var.slot = allocSlot();
            emit(Op.storeLocal, v.var.slot);
        }
        else if (auto a = cast(AssignStmt) s)
        {
            if (auto pe = cast(PathExpr) a.target)
            {
                expr(a.value);
                emit(Op.storeLocal, pe.var.slot);
            }
            else
            {
                auto ix = cast(IndexExpr) a.target;
                expr(ix.base);
                expr(ix.index);
                expr(a.value);
                emit(Op.indexSet);
            }
        }
        else if (auto x = cast(ExprStmt) s)
        {
            expr(x.e);
            emit(Op.pop);
        }
        else if (auto r = cast(ReturnStmt) s)
        {
            if (r.value is null)
                emit(Op.retUnit);
            else
            {
                expr(r.value);
                emit(Op.ret);
            }
        }
        else if (auto wh = cast(WhileStmt) s)
        {
            auto lc = new LoopCtx;
            lc.depth = cur.depth;
            int top = here();
            lc.contTarget = top;
            expr(wh.cond);
            int exitJ = emitJump(Op.jumpIfFalse);
            cur.loops ~= lc;
            stmtBlock(wh.body);
            cur.loops.length = cur.loops.length - 1;
            emit(Op.jump, top);
            patch(exitJ);
            patchAll(lc.breaks);
        }
        else if (auto f = cast(ForStmt) s)
            forStmt(f);
        else if (cast(BreakStmt) s)
        {
            auto lc = cur.loops[$ - 1];
            int d = cur.depth;
            while (cur.depth > lc.depth)
                emit(Op.pop);
            lc.breaks ~= emitJump(Op.jump);
            cur.depth = d;
        }
        else if (cast(ContinueStmt) s)
        {
            auto lc = cur.loops[$ - 1];
            int d = cur.depth;
            while (cur.depth > lc.depth)
                emit(Op.pop);
            if (lc.contTarget >= 0)
                emit(Op.jump, lc.contTarget);
            else
                lc.continues ~= emitJump(Op.jump);
            cur.depth = d;
        }
        else
            assert(0);
    }

    private void stmtBlock(Block b)
    {
        int saved = cur.nextSlot;
        foreach (s; b.stmts)
            stmt(s);
        if (b.trailing !is null)
        {
            expr(b.trailing);
            emit(Op.pop);
        }
        cur.nextSlot = saved;
    }

    private void forStmt(ForStmt f)
    {
        int saved = cur.nextSlot;
        auto lc = new LoopCtx;
        lc.depth = cur.depth;
        int seqSlot = allocSlot();
        int idxSlot = allocSlot();
        int top;
        int exitJ;
        if (f.hi is null)
        {
            expr(f.iter);
            emit(Op.storeLocal, seqSlot);
            emit(Op.pushConst, constInt(0));
            emit(Op.storeLocal, idxSlot);
            top = here();
            emit(Op.loadLocal, idxSlot);
            emit(Op.seqLen, seqSlot);
            emit(Op.lt);
            exitJ = emitJump(Op.jumpIfFalse);
            emit(Op.seqGet, seqSlot, idxSlot);
        }
        else
        {
            // seqSlot holds the bound for range loops
            expr(f.iter);
            emit(Op.storeLocal, idxSlot);
            expr(f.hi);
            emit(Op.storeLocal, seqSlot);
            top = here();
            emit(Op.loadLocal, idxSlot);
            emit(Op.loadLocal, seqSlot);
            emit(Op.lt);
            exitJ = emitJump(Op.jumpIfFalse);
            emit(Op.loadLocal, idxSlot);
        }
        int bodySaved = cur.nextSlot;
        bindFromStack(f.pat);
        cur.loops ~= lc;
        stmtBlock(f.body);
        cur.loops.length = cur.loops.length - 1;
        cur.nextSlot = bodySaved;
        patchAll(lc.continues);
        emit(Op.incLocal, idxSlot);
        emit(Op.jump, top);
        patch(exitJ);
        patchAll(lc.breaks);
        cur.nextSlot = saved;
    }

    // ------------------------------------------------------------ patterns

    /// Consumes the value on top of the stack, binding the (irrefutable) pattern.
    private void bindFromStack(Pat p)
    {
        if (cast(WildPat) p)
        {
            emit(Op.pop);
            return;
        }
        if (auto ip = cast(IdentPat) p)
        {
            if (ip.enumDecl is null)
            {
                ip.var.slot = allocSlot();
                emit(Op.storeLocal, ip.var.slot);
                return;
            }
        }
        int t = allocSlot();
        emit(Op.storeLocal, t);
        int[] fails;
        pattern(p, t, fails);
        patchAll(fails);
    }

    /// Emits the test and bindings for pattern `p` against the value in `slot`.
    /// Failing tests are appended to `fails` as jump-operand indices to patch.
    private void pattern(Pat p, int slot, ref int[] fails)
    {
        if (cast(WildPat) p)
            return;
        if (auto ip = cast(IdentPat) p)
        {
            if (ip.enumDecl is null)
                ip.var.slot = slot;
            else if (ip.enumDecl.variants.length > 1)
                fails ~= emitTest(Op.jumpUnlessVariant, slot, ip.variantIdx);
            return;
        }
        if (auto lp = cast(LitPat) p)
        {
            emit(Op.loadLocal, slot);
            literal(lp);
            emit(Op.eq);
            fails ~= emitJump(Op.jumpIfFalse);
            return;
        }
        if (auto tp = cast(TuplePat) p)
        {
            foreach (i, s; tp.subs)
                subPattern(s, Op.pushTuple, slot, cast(int) i, fails);
            return;
        }
        if (auto lp = cast(ListPat) p)
        {
            int n = cast(int) lp.subs.length;
            if (lp.hasRest)
            {
                if (n > 0)
                    fails ~= emitTest(Op.jumpUnlessLenGe, slot, n);
            }
            else
                fails ~= emitTest(Op.jumpUnlessLen, slot, n);
            foreach (i, s; lp.subs)
                subPattern(s, Op.pushElem, slot, cast(int) i, fails);
            if (lp.restVar !is null)
            {
                emit(Op.listRest, slot, n);
                lp.restVar.slot = allocSlot();
                emit(Op.storeLocal, lp.restVar.slot);
            }
            return;
        }
        if (auto sp = cast(StructPat) p)
        {
            foreach (fp; sp.fields)
                subPattern(fp.sub, Op.pushField, slot, fp.fieldIdx, fails);
            return;
        }
        if (auto vp = cast(VariantPat) p)
        {
            if (vp.enumDecl.variants.length > 1)
                fails ~= emitTest(Op.jumpUnlessVariant, slot, vp.variantIdx);
            foreach (i, s; vp.subs)
                subPattern(s, Op.pushPayload, slot, cast(int) i, fails);
            return;
        }
        assert(0);
    }

    private void literal(LitPat lp)
    {
        final switch (lp.kind)
        {
        case LitPat.Kind.int_:
            emit(Op.pushConst, constInt(lp.iv));
            break;
        case LitPat.Kind.char_:
            emit(Op.pushConst, constChar(cast(dchar) lp.iv));
            break;
        case LitPat.Kind.str:
            emit(Op.pushConst, constStr(lp.sv));
            break;
        case LitPat.Kind.bool_:
            emit(lp.iv ? Op.pushTrue : Op.pushFalse);
            break;
        case LitPat.Kind.float_:
            assert(0);
        }
    }

    private void subPattern(Pat sub, Op pushOp, int slot, int idx, ref int[] fails)
    {
        if (cast(WildPat) sub)
            return;
        if (auto lp = cast(LitPat) sub)
        {
            emit(pushOp, slot, idx);
            literal(lp);
            emit(Op.eq);
            fails ~= emitJump(Op.jumpIfFalse);
            return;
        }
        emit(pushOp, slot, idx);
        int t = allocSlot();
        emit(Op.storeLocal, t);
        pattern(sub, t, fails);
    }

    // ------------------------------------------------------------ expressions

    private void pushVar(LocalVar v)
    {
        if (v.owner is cur.info)
            emit(Op.loadLocal, v.slot);
        else
            emit(Op.loadUpval, cur.info.captureIndex(v));
    }

    private void expr(Expr e)
    {
        if (auto x = cast(IntLit) e)
            emit(Op.pushConst, constInt(x.v));
        else if (auto x = cast(FloatLit) e)
            emit(Op.pushConst, constFloat(x.v));
        else if (auto x = cast(StrLit) e)
            emit(Op.pushConst, constStr(x.v));
        else if (auto x = cast(CharLit) e)
            emit(Op.pushConst, constChar(x.v));
        else if (auto x = cast(BoolLit) e)
            emit(x.v ? Op.pushTrue : Op.pushFalse);
        else if (auto x = cast(SelfExpr) e)
            pushVar(x.var);
        else if (auto x = cast(PathExpr) e)
        {
            if (x.res == PathExpr.Res.local)
                pushVar(x.var);
            else
                emit(Op.makeEnum, x.enumDecl.id, x.variantIdx, 0);
        }
        else if (auto x = cast(Call) e)
            callExpr(x);
        else if (auto x = cast(MethodCall) e)
        {
            expr(x.recv);
            foreach (a; x.args)
                expr(a);
            emit(Op.callMethod, x.trait.id, x.methodIdx, cast(int) x.args.length);
        }
        else if (auto x = cast(Binary) e)
            binary(x);
        else if (auto x = cast(Unary) e)
        {
            expr(x.e);
            switch (x.op)
            {
            case Tk.minus:
                emit(prune(x.ty).k == TK.float_ ? Op.negF : Op.negI);
                break;
            case Tk.bang:
                emit(Op.notB);
                break;
            case Tk.tilde:
                emit(Op.bnot);
                break;
            default:
                assert(0);
            }
        }
        else if (auto x = cast(IndexExpr) e)
        {
            expr(x.base);
            expr(x.index);
            emit(Op.indexGet);
        }
        else if (auto x = cast(FieldExpr) e)
        {
            expr(x.base);
            emit(Op.getField, x.fieldIdx);
        }
        else if (auto x = cast(StructLit) e)
            structLit(x);
        else if (auto x = cast(ListLit) e)
        {
            foreach (a; x.elems)
                expr(a);
            emit(Op.makeList, cast(int) x.elems.length);
        }
        else if (auto x = cast(MapLit) e)
        {
            foreach (i; 0 .. x.keys.length)
            {
                expr(x.keys[i]);
                expr(x.vals[i]);
            }
            emit(Op.makeMap, cast(int) x.keys.length);
        }
        else if (auto x = cast(TupleLit) e)
        {
            foreach (a; x.elems)
                expr(a);
            emit(Op.makeTuple, cast(int) x.elems.length);
        }
        else if (auto x = cast(Lambda) e)
            lambda(x);
        else if (auto x = cast(IfExpr) e)
            ifExpr(x);
        else if (auto x = cast(MatchExpr) e)
            matchExpr(x);
        else if (auto x = cast(Block) e)
            blockExpr(x);
        else
            assert(0);
    }

    private void blockExpr(Block b)
    {
        int saved = cur.nextSlot;
        foreach (s; b.stmts)
            stmt(s);
        if (b.trailing !is null)
            expr(b.trailing);
        else
            emit(Op.pushUnit);
        cur.nextSlot = saved;
    }

    private void callExpr(Call c)
    {
        final switch (c.kind)
        {
        case Call.Kind.func:
            foreach (a; c.args)
                expr(a);
            emit(Op.call, c.fn.index, cast(int) c.args.length);
            break;
        case Call.Kind.builtin:
            foreach (a; c.args)
                expr(a);
            emit(Op.callBuiltin, c.builtin.index, cast(int) c.args.length);
            break;
        case Call.Kind.variant:
            foreach (a; c.args)
                expr(a);
            emit(Op.makeEnum, c.enumDecl.id, c.variantIdx, cast(int) c.args.length);
            break;
        case Call.Kind.traitMethod:
            foreach (a; c.args)
                expr(a);
            emit(Op.callMethod, c.trait.id, c.methodIdx, cast(int) c.args.length - 1);
            break;
        case Call.Kind.indirect:
            expr(c.callee);
            foreach (a; c.args)
                expr(a);
            emit(Op.callValue, cast(int) c.args.length);
            break;
        }
    }

    private void structLit(StructLit s)
    {
        int n = cast(int) s.decl.fields.length;
        bool identity = true;
        foreach (i; 0 .. n)
            if (s.declToInit[i] != i)
                identity = false;
        if (identity)
        {
            foreach (fi; s.inits)
                expr(fi.value);
        }
        else
        {
            int saved = cur.nextSlot;
            int[] tmp;
            foreach (fi; s.inits)
            {
                expr(fi.value);
                int t = allocSlot();
                emit(Op.storeLocal, t);
                tmp ~= t;
            }
            foreach (i; 0 .. n)
                emit(Op.loadLocal, tmp[s.declToInit[i]]);
            cur.nextSlot = saved;
        }
        emit(Op.makeStruct, s.decl.id, n);
    }

    private void binary(Binary b)
    {
        if (b.op == Tk.andAnd)
        {
            expr(b.l);
            int d = cur.depth;
            int jf = emitJump(Op.jumpIfFalse);
            expr(b.r);
            int je = emitJump(Op.jump);
            cur.depth = d - 1 + 0;
            patch(jf);
            cur.depth = d - 1;
            emit(Op.pushFalse);
            patch(je);
            return;
        }
        if (b.op == Tk.orOr)
        {
            expr(b.l);
            int d = cur.depth;
            int jt = emitJump(Op.jumpIfTrue);
            expr(b.r);
            int je = emitJump(Op.jump);
            patch(jt);
            cur.depth = d - 1;
            emit(Op.pushTrue);
            patch(je);
            return;
        }
        expr(b.l);
        expr(b.r);
        bool isF = prune(b.ty).k == TK.float_;
        switch (b.op)
        {
        case Tk.plus:
            emit(isF ? Op.addF : Op.addI);
            break;
        case Tk.minus:
            emit(isF ? Op.subF : Op.subI);
            break;
        case Tk.star:
            emit(isF ? Op.mulF : Op.mulI);
            break;
        case Tk.slash:
            emit(isF ? Op.divF : Op.divI);
            break;
        case Tk.percent:
            emit(Op.modI);
            break;
        case Tk.plusPlus:
            emit(prune(b.ty).k == TK.str ? Op.concatStr : Op.concatList);
            break;
        case Tk.amp:
            emit(Op.band);
            break;
        case Tk.pipe:
            emit(Op.bor);
            break;
        case Tk.caret:
            emit(Op.bxor);
            break;
        case Tk.shl:
            emit(Op.shl);
            break;
        case Tk.shr:
            emit(Op.shr);
            break;
        case Tk.eqEq:
            emit(Op.eq);
            break;
        case Tk.notEq:
            emit(Op.ne);
            break;
        case Tk.lt:
            emit(Op.lt);
            break;
        case Tk.ltEq:
            emit(Op.le);
            break;
        case Tk.gt:
            emit(Op.gt);
            break;
        case Tk.gtEq:
            emit(Op.ge);
            break;
        default:
            assert(0);
        }
    }

    private void lambda(Lambda l)
    {
        auto saved = cur;
        int idx = cast(int) prog.funcs.length;
        auto fc = new FuncCode;
        fc.name = "<lambda>";
        prog.funcs ~= fc;
        l.info.index = idx;
        auto st = new FnState;
        st.info = l.info;
        cur = st;
        foreach (ref p; l.params)
            p.var.slot = allocSlot();
        compileBody(l.body);
        finishFn(fc, st, cast(int) l.params.length);
        cur = saved;
        foreach (cap; l.info.captures)
            pushVar(cap);
        emit(Op.makeClosure, idx, cast(int) l.info.captures.length);
    }

    private void ifExpr(IfExpr i)
    {
        expr(i.cond);
        int jf = emitJump(Op.jumpIfFalse);
        int d = cur.depth;
        expr(i.then);
        int je = emitJump(Op.jump);
        cur.depth = d;
        patch(jf);
        if (i.els !is null)
            expr(i.els);
        else
            emit(Op.pushUnit);
        patch(je);
    }

    private void matchExpr(MatchExpr m)
    {
        int saved = cur.nextSlot;
        expr(m.scrut);
        int slot = allocSlot();
        emit(Op.storeLocal, slot);
        int d = cur.depth;
        int[] ends;
        foreach (arm; m.arms)
        {
            int armSaved = cur.nextSlot;
            int[] fails;
            pattern(arm.pat, slot, fails);
            if (arm.guard !is null)
            {
                expr(arm.guard);
                fails ~= emitJump(Op.jumpIfFalse);
            }
            expr(arm.body);
            ends ~= emitJump(Op.jump);
            cur.depth = d;
            patchAll(fails);
            cur.nextSlot = armSaved;
        }
        emit(Op.noMatch);
        patchAll(ends);
        cur.depth = d + 1;
        if (cur.depth > cur.maxDepth)
            cur.maxDepth = cur.depth;
        cur.nextSlot = saved;
    }
}

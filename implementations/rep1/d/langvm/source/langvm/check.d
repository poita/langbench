/// The type checker (pass 4): bidirectional inference, name resolution in bodies, patterns.
module langvm.check;

import langvm.ast;
import langvm.diag;
import langvm.lexer : Tk;
import langvm.model;
import langvm.patterns;
import langvm.resolve;
import langvm.world;

/// Unifies two types, binding inference variables (with occurs check).
bool unify(Type a, Type b)
{
    a = prune(a);
    b = prune(b);
    if (a is b)
        return true;
    if (a.k == TK.var)
    {
        if (occurs(a, b))
            return false;
        a.link = b;
        return true;
    }
    if (b.k == TK.var)
    {
        if (occurs(b, a))
            return false;
        b.link = a;
        return true;
    }
    if (a.k != b.k)
        return false;
    if (a.k == TK.named && a.decl !is b.decl)
        return false;
    if (a.k == TK.param)
        return a.tp is b.tp;
    if (a.args.length != b.args.length)
        return false;
    foreach (i; 0 .. a.args.length)
        if (!unify(a.args[i], b.args[i]))
            return false;
    return true;
}

private final class FuncCtx
{
    FuncInfo info;
    FuncCtx parent;
    /// Declared/expected return type; null when not yet known (synthesised lambda).
    Type ret;
    int loopDepth;
}

private struct DeferredKey
{
    Type key;
    Pos pos;
}

private struct PatEnv
{
    LocalVar[] bindings;
}

/// Whether control cannot flow past the expression (section 11.6).
bool diverges(Expr e)
{
    if (auto b = cast(Block) e)
    {
        foreach (s; b.stmts)
            if (stmtDiverges(s))
                return true;
        return b.trailing !is null && diverges(b.trailing);
    }
    if (auto i = cast(IfExpr) e)
        return i.els !is null && diverges(i.then) && diverges(i.els);
    if (auto m = cast(MatchExpr) e)
    {
        if (m.arms.length == 0)
            return false;
        foreach (a; m.arms)
            if (!diverges(a.body))
                return false;
        return true;
    }
    return false;
}

private bool stmtDiverges(Stmt s)
{
    if (cast(ReturnStmt) s || cast(BreakStmt) s || cast(ContinueStmt) s)
        return true;
    if (auto l = cast(LetStmt) s)
        return diverges(l.init);
    if (auto v = cast(VarStmt) s)
        return diverges(v.init);
    if (auto a = cast(AssignStmt) s)
        return diverges(a.value);
    if (auto x = cast(ExprStmt) s)
        return diverges(x.e);
    return false;
}

/// Checks every body of the program.
final class Checker
{
    private World w;
    private ModuleDecl mod;
    private TyScope sc;
    private FuncCtx ctx;
    private LocalVar[] vars;
    private size_t[] marks;
    private Type[][] owners;
    private DeferredKey[][] deferred;

    this(World w)
    {
        this.w = w;
    }

    /// Runs pass 4 over all modules.
    /// Throws: [CompileError].
    void run()
    {
        foreach (mi; w.modules)
        {
            foreach (it; mi.ast.items)
            {
                if (auto f = cast(FnItem) it)
                    checkFunction(f.decl);
                else if (auto t = cast(TraitItem) it)
                {
                    foreach (md; t.decl.methods)
                        if (md.hasDefault)
                            checkFunction(md.defaultFn);
                }
                else if (auto im = cast(ImplAst) it)
                {
                    foreach (fd; im.decl.methods)
                        checkFunction(fd);
                }
            }
        }
    }

    // ------------------------------------------------------------ scopes

    private void pushScope()
    {
        marks ~= vars.length;
    }

    private void popScope()
    {
        vars.length = marks[$ - 1];
        marks.length = marks.length - 1;
    }

    private void declare(LocalVar v)
    {
        vars ~= v;
    }

    private LocalVar lookupLocal(string name)
    {
        for (size_t i = vars.length; i > 0; i--)
            if (vars[i - 1].name == name)
                return vars[i - 1];
        return null;
    }

    private LocalVar newVar(string name, Type t, bool mutable, Pos pos)
    {
        auto v = new LocalVar;
        v.name = name;
        v.ty = t;
        v.mutable = mutable;
        v.owner = ctx.info;
        v.pos = pos;
        return v;
    }

    private void noteUse(LocalVar v)
    {
        if (v.owner is ctx.info)
            return;
        for (auto c = ctx; c !is null && c.info !is v.owner; c = c.parent)
        {
            if (c.info.captureIndex(v) < 0)
                c.info.captures ~= v;
        }
    }

    // ------------------------------------------------------------ inference variables

    private Type fresh()
    {
        auto v = freshVar();
        if (owners.length)
            owners[$ - 1] ~= v;
        return v;
    }

    private void beginOwner()
    {
        owners ~= cast(Type[]) null;
        deferred ~= cast(DeferredKey[]) null;
    }

    private void endOwner(Pos pos)
    {
        foreach (d; deferred[$ - 1])
        {
            if (isGround(d.key) && !holdsKey(w, d.key))
                fail("bad-key-type", d.pos);
        }
        foreach (v; owners[$ - 1])
            if (!isGround(v))
                fail("cannot-infer", pos);
        foreach (d; deferred[$ - 1])
            if (!holdsKey(w, d.key))
                fail("bad-key-type", d.pos);
        owners.length = owners.length - 1;
        deferred.length = deferred.length - 1;
    }

    // ------------------------------------------------------------ functions

    private void checkFunction(FuncDecl fd)
    {
        mod = fd.mod;
        sc = TyScope(fd.mod, fd.tparams, fd.selfType);
        auto info = new FuncInfo;
        fd.info = info;
        ctx = new FuncCtx;
        ctx.info = info;
        ctx.ret = fd.ret;
        vars.length = 0;
        marks.length = 0;
        owners.length = 0;
        deferred.length = 0;
        pushScope();
        if (fd.selfType !is null)
        {
            fd.selfVar = newVar("self", fd.selfType, false, fd.pos);
            declare(fd.selfVar);
        }
        foreach (i, n; fd.paramNames)
        {
            auto v = newVar(n, fd.paramTypes[i], false, fd.paramPos[i]);
            fd.paramVars ~= v;
            declare(v);
        }
        checkBody(fd.body, fd.ret, fd.pos);
        popScope();
    }

    /// Checks a function/lambda body block against the return type (section 11.6).
    private void checkBody(Expr body_, Type ret, Pos missingPos)
    {
        if (auto b = cast(Block) body_)
        {
            pushScope();
            foreach (s; b.stmts)
                checkStmt(s);
            if (b.trailing !is null)
                b.ty = tc(b.trailing, ret);
            else
            {
                if (prune(ret).k != TK.unit && !diverges(b))
                    fail("missing-return", missingPos);
                b.ty = ret;
            }
            popScope();
        }
        else
            tc(body_, ret);
    }

    // ------------------------------------------------------------ statements

    private void checkStmt(Stmt s)
    {
        if (auto l = cast(LetStmt) s)
        {
            Type t;
            if (l.te !is null)
            {
                t = resolveType(w, sc, l.te);
                tc(l.init, t);
            }
            else
                t = tc(l.init, null);
            PatEnv env;
            checkPat(l.pat, t, env);
            if (!irrefutable(l.pat))
                fail("refutable-pattern", l.pat.pos);
            foreach (b; env.bindings)
                declare(b);
        }
        else if (auto v = cast(VarStmt) s)
        {
            Type t;
            if (v.te !is null)
            {
                t = resolveType(w, sc, v.te);
                tc(v.init, t);
            }
            else
                t = tc(v.init, null);
            v.var = newVar(v.name, t, true, v.namePos);
            declare(v.var);
        }
        else if (auto a = cast(AssignStmt) s)
            checkAssign(a);
        else if (auto x = cast(ExprStmt) s)
            tc(x.e, null);
        else if (auto r = cast(ReturnStmt) s)
            checkReturn(r);
        else if (auto wh = cast(WhileStmt) s)
        {
            tc(wh.cond, tBool);
            ctx.loopDepth++;
            checkStmtBlock(wh.body);
            ctx.loopDepth--;
        }
        else if (auto f = cast(ForStmt) s)
            checkFor(f);
        else if (cast(BreakStmt) s || cast(ContinueStmt) s)
        {
            if (ctx.loopDepth == 0)
                fail("break-outside", s.pos);
        }
        else
            assert(0);
    }

    private void checkStmtBlock(Block b)
    {
        pushScope();
        foreach (s; b.stmts)
            checkStmt(s);
        if (b.trailing !is null)
            b.ty = tc(b.trailing, null);
        popScope();
    }

    private void checkReturn(ReturnStmt r)
    {
        if (ctx.ret is null)
            fail("cannot-infer", r.pos);
        if (r.value is null)
        {
            if (prune(ctx.ret).k != TK.unit)
                fail("type-mismatch", r.pos);
            return;
        }
        if (prune(ctx.ret).k == TK.unit)
        {
            auto s = tc(r.value, null);
            if (prune(s).k != TK.unit)
                fail("type-mismatch", r.pos);
        }
        else
            tc(r.value, ctx.ret);
    }

    private void checkFor(ForStmt f)
    {
        Type elem;
        if (f.hi !is null)
        {
            tc(f.iter, tInt);
            tc(f.hi, tInt);
            elem = tInt;
        }
        else
        {
            auto s = prune(tc(f.iter, null));
            if (s.k == TK.list)
                elem = s.args[0];
            else if (s.k == TK.str)
                elem = tChar;
            else
                fail("not-iterable", f.iter.pos);
        }
        PatEnv env;
        checkPat(f.pat, elem, env);
        if (!irrefutable(f.pat))
            fail("refutable-pattern", f.pat.pos);
        pushScope();
        foreach (b; env.bindings)
            declare(b);
        ctx.loopDepth++;
        checkStmtBlock(f.body);
        ctx.loopDepth--;
        popScope();
    }

    private void checkAssign(AssignStmt a)
    {
        auto pe = cast(PathExpr) a.target;
        auto ix = cast(IndexExpr) a.target;
        if (pe is null && ix is null || (pe !is null && pe.qual.length))
            fail("bad-target", a.target.pos);
        if (pe !is null)
        {
            auto lv = lookupLocal(pe.name);
            if (lv is null)
                fail("unknown-name", pe.namePos);
            if (!lv.mutable)
                fail("assign-immutable", pe.namePos);
            if (lv.owner !is ctx.info)
                fail("assign-captured", pe.namePos);
            pe.res = PathExpr.Res.local;
            pe.var = lv;
            pe.ty = lv.ty;
            tc(a.value, lv.ty);
            return;
        }
        auto at = prune(tc(ix.base, null));
        if (at.k == TK.list)
        {
            tc(ix.index, tInt);
            tc(a.value, at.args[0]);
        }
        else if (at.k == TK.map)
        {
            tc(ix.index, at.args[0]);
            tc(a.value, at.args[1]);
        }
        else
            fail("bad-target", ix.base.pos);
    }

    // ------------------------------------------------------------ expressions

    private Type finish(Expr e, Type s, Type exp)
    {
        if (exp !is null && !unify(exp, s))
            fail("type-mismatch", e.pos);
        e.ty = s;
        return s;
    }

    /// Type-checks `e`. With `exp == null` this is synthesis (`infer`); otherwise checking against `exp`.
    private Type tc(Expr e, Type exp)
    {
        if (auto x = cast(IntLit) e)
            return finish(e, tInt, exp);
        if (auto x = cast(FloatLit) e)
            return finish(e, tFloat, exp);
        if (auto x = cast(StrLit) e)
            return finish(e, tStr, exp);
        if (auto x = cast(CharLit) e)
            return finish(e, tChar, exp);
        if (auto x = cast(BoolLit) e)
            return finish(e, tBool, exp);
        if (auto x = cast(PathExpr) e)
            return pathExpr(x, exp);
        if (auto x = cast(SelfExpr) e)
        {
            auto lv = lookupLocal("self");
            if (lv is null)
                fail("self-outside", e.pos);
            noteUse(lv);
            x.var = lv;
            return finish(e, lv.ty, exp);
        }
        if (auto x = cast(Call) e)
            return callExpr(x, exp);
        if (auto x = cast(MethodCall) e)
            return methodCall(x, exp);
        if (auto x = cast(Binary) e)
            return binary(x, exp);
        if (auto x = cast(Unary) e)
            return unary(x, exp);
        if (auto x = cast(IndexExpr) e)
            return indexExpr(x, exp);
        if (auto x = cast(FieldExpr) e)
            return fieldExpr(x, exp);
        if (auto x = cast(StructLit) e)
            return structLit(x, exp);
        if (auto x = cast(ListLit) e)
            return listLit(x, exp);
        if (auto x = cast(MapLit) e)
            return mapLit(x, exp);
        if (auto x = cast(TupleLit) e)
            return tupleLit(x, exp);
        if (auto x = cast(Lambda) e)
            return lambda(x, exp);
        if (auto x = cast(IfExpr) e)
            return ifExpr(x, exp);
        if (auto x = cast(MatchExpr) e)
            return matchExpr(x, exp);
        if (auto x = cast(Block) e)
            return blockExpr(x, exp);
        assert(0);
    }

    // ---- paths

    private Type variantRet(DataDecl d)
    {
        Type[] args;
        foreach (tp; d.tparams)
            args ~= paramOf(tp);
        return namedOf(d, args);
    }

    private void setFromItem(PathExpr pe, ValueItem vi)
    {
        final switch (vi.kind)
        {
        case ValueItem.Kind.func:
            pe.res = PathExpr.Res.func;
            pe.fn = vi.fn;
            break;
        case ValueItem.Kind.builtin:
            pe.res = PathExpr.Res.builtin;
            pe.builtin = vi.builtin;
            break;
        case ValueItem.Kind.variant:
            pe.res = PathExpr.Res.variant;
            pe.enumDecl = vi.enumDecl;
            pe.variantIdx = vi.variantIdx;
            break;
        }
    }

    private TraitDecl findVisibleTrait(string name)
    {
        if (auto pt = name in mod.traits)
            return *pt;
        foreach (bound; mod.importOrder)
        {
            auto im = mod.imports[bound];
            if (im is mod)
                continue;
            if (auto pt = name in im.traits)
                if (pt.pub)
                    return *pt;
        }
        switch (name)
        {
        case "Eq":
            return w.trEq;
        case "Ord":
            return w.trOrd;
        case "Key":
            return w.trKey;
        default:
            return null;
        }
    }

    private bool isTypeName(string n)
    {
        switch (n)
        {
        case "Int", "Float", "Bool", "Char", "Str", "Unit", "Self":
            return true;
        default:
            return (n in mod.types) !is null || (n in w.prelude.types) !is null;
        }
    }

    /// Looks up a value-namespace item for a pattern or expression path (not locals).
    /// Returns null for a trait-method path (and sets `traitOut`/`methodOut`).
    private ValueItem lookupValueItem(string qual, Pos qualPos, string name, Pos namePos,
        out TraitDecl traitOut, out int methodOut)
    {
        if (qual.length == 0)
        {
            if (auto p = name in mod.values)
                return *p;
            if (auto p = name in w.prelude.values)
                return *p;
            return null;
        }
        if (auto pm = qual in mod.imports)
        {
            auto m = *pm;
            auto p = name in m.values;
            if (p is null)
                fail("unknown-name", namePos);
            if (!p.pub && m !is mod)
                fail("not-public", namePos);
            return *p;
        }
        auto tr = findVisibleTrait(qual);
        if (tr is null)
            fail("unknown-module", qualPos);
        int mi = tr.methodIndex(name);
        if (mi < 0)
            fail("unknown-name", namePos);
        traitOut = tr;
        methodOut = mi;
        return null;
    }

    private void resolvePath(PathExpr pe)
    {
        if (pe.qual.length == 0)
        {
            if (auto lv = lookupLocal(pe.name))
            {
                pe.res = PathExpr.Res.local;
                pe.var = lv;
                noteUse(lv);
                return;
            }
        }
        TraitDecl tr;
        int mi;
        auto vi = lookupValueItem(pe.qual, pe.qualPos, pe.name, pe.namePos, tr, mi);
        if (vi is null)
        {
            if (tr is null)
            {
                if (pe.qual.length == 0 && isTypeName(pe.name))
                    fail("bad-value-ref", pe.namePos);
                fail("unknown-name", pe.namePos);
            }
            pe.res = PathExpr.Res.traitMethod;
            pe.trait = tr;
            pe.methodIdx = mi;
            return;
        }
        setFromItem(pe, vi);
    }

    private Type pathExpr(PathExpr pe, Type exp)
    {
        resolvePath(pe);
        final switch (pe.res)
        {
        case PathExpr.Res.none:
            assert(0);
        case PathExpr.Res.local:
            return finish(pe, pe.var.ty, exp);
        case PathExpr.Res.func, PathExpr.Res.builtin, PathExpr.Res.traitMethod:
            fail("bad-value-ref", pe.namePos);
        case PathExpr.Res.variant:
            {
                auto d = pe.enumDecl;
                auto v = d.variants[pe.variantIdx];
                if (v.payload.length > 0)
                    fail("bad-value-ref", pe.namePos);
                auto t = genericCall(pe.pos, d.tparams, null, variantRet(d), null, exp);
                pe.ty = t;
                return t;
            }
        }
    }

    // ---- calls

    private Type genericCall(Pos calleePos, TypeParam[] tps, Type[] params, Type ret, Expr[] args, Type exp)
    {
        if (args.length != params.length)
            fail("arity", calleePos);
        beginOwner();
        Type[] vs;
        foreach (_; tps)
            vs ~= fresh();
        foreach (i, a; args)
            tc(a, subst(params[i], tps, vs));
        auto r = subst(ret, tps, vs);
        if (exp !is null && !unify(r, exp))
            fail("type-mismatch", calleePos);
        // the owner list holds all variables including the callee's own
        endOwner(calleePos);
        foreach (i, tp; tps)
            foreach (b; tp.bounds)
                if (!satisfies(w, zonk(vs[i]), b))
                    fail("unsatisfied-bound", calleePos);
        return zonk(r);
    }

    private Type callExpr(Call c, Type exp)
    {
        auto callee = c.callee;
        auto pe = cast(PathExpr) callee;
        if (pe !is null)
        {
            if (c.args.length > 16)
                fail("bad-arity", pe.pos);
            resolvePath(pe);
            switch (pe.res)
            {
            case PathExpr.Res.func:
                {
                    c.kind = Call.Kind.func;
                    c.fn = pe.fn;
                    auto fd = pe.fn;
                    auto t = genericCall(pe.pos, fd.tparams, fd.paramTypes, fd.ret, c.args, exp);
                    c.ty = t;
                    return t;
                }
            case PathExpr.Res.builtin:
                {
                    c.kind = Call.Kind.builtin;
                    c.builtin = pe.builtin;
                    auto b = pe.builtin;
                    auto t = genericCall(pe.pos, b.tparams, b.paramTypes, b.ret, c.args, exp);
                    c.ty = t;
                    return t;
                }
            case PathExpr.Res.variant:
                {
                    c.kind = Call.Kind.variant;
                    c.enumDecl = pe.enumDecl;
                    c.variantIdx = pe.variantIdx;
                    auto d = pe.enumDecl;
                    auto t = genericCall(pe.pos, d.tparams, d.variants[pe.variantIdx].payload, variantRet(d), c.args, exp);
                    c.ty = t;
                    return t;
                }
            case PathExpr.Res.traitMethod:
                return traitPathCall(c, pe, exp);
            default:
                break; // local: indirect
            }
        }
        else if (c.args.length > 16)
            fail("bad-arity", callee.pos);
        c.kind = Call.Kind.indirect;
        auto ft = prune(tc(callee, null));
        if (ft.k != TK.fn)
            fail("not-callable", callee.pos);
        auto ps = fnParams(ft);
        if (ps.length != c.args.length)
            fail("arity", callee.pos);
        foreach (i, a; c.args)
            tc(a, ps[i]);
        return finish(c, fnRet(ft), exp);
    }

    private Type methodSigCall(Expr whole, TraitDecl tr, int midx, Type recvTy, Expr[] args, Pos namePos, Type exp)
    {
        auto md = tr.methods[midx];
        if (args.length != md.paramTypes.length)
            fail("arity", namePos);
        if (!satisfies(w, recvTy, tr))
            fail("unsatisfied-bound", namePos);
        auto from = [tr.selfParam];
        auto to = [recvTy];
        foreach (i, a; args)
            tc(a, subst(md.paramTypes[i], from, to));
        return finish(whole, subst(md.ret, from, to), exp);
    }

    private Type traitPathCall(Call c, PathExpr pe, Type exp)
    {
        c.kind = Call.Kind.traitMethod;
        c.trait = pe.trait;
        c.methodIdx = pe.methodIdx;
        if (c.args.length == 0)
            fail("arity", pe.namePos);
        auto r = tc(c.args[0], null);
        return methodSigCall(c, pe.trait, pe.methodIdx, r, c.args[1 .. $], pe.namePos, exp);
    }

    private Type methodCall(MethodCall mc, Type exp)
    {
        if (mc.args.length > 16)
            fail("bad-arity", mc.namePos);
        auto r = tc(mc.recv, null);
        TraitDecl found;
        int count = 0;
        foreach (t; w.visibleTraits(mod))
        {
            if (t.methodIndex(mc.name) >= 0)
            {
                count++;
                found = t;
            }
        }
        if (count == 0)
            fail("no-method", mc.namePos);
        if (count > 1)
            fail("ambig-method", mc.namePos);
        mc.trait = found;
        mc.methodIdx = found.methodIndex(mc.name);
        return methodSigCall(mc, found, mc.methodIdx, r, mc.args, mc.namePos, exp);
    }

    // ---- operators

    private Type binary(Binary b, Type exp)
    {
        switch (b.op)
        {
        case Tk.plus, Tk.minus, Tk.star, Tk.slash, Tk.percent:
            {
                auto l = prune(tc(b.l, null));
                if (l.k != TK.int_ && l.k != TK.float_)
                    fail("type-mismatch", b.l.pos);
                if (b.op == Tk.percent && l.k == TK.float_)
                    fail("type-mismatch", b.l.pos);
                tc(b.r, l);
                return finish(b, l, exp);
            }
        case Tk.plusPlus:
            {
                auto l = prune(tc(b.l, null));
                if (l.k != TK.str && l.k != TK.list)
                    fail("type-mismatch", b.l.pos);
                tc(b.r, l);
                return finish(b, l, exp);
            }
        case Tk.amp, Tk.pipe, Tk.caret, Tk.shl, Tk.shr:
            tc(b.l, tInt);
            tc(b.r, tInt);
            return finish(b, tInt, exp);
        case Tk.lt, Tk.ltEq, Tk.gt, Tk.gtEq:
            {
                auto l = tc(b.l, null);
                if (!holdsOrd(w, l))
                    fail("not-ord", b.l.pos);
                tc(b.r, l);
                return finish(b, tBool, exp);
            }
        case Tk.eqEq, Tk.notEq:
            {
                auto l = tc(b.l, null);
                DataDecl[] assumed;
                if (!holdsEq(w, l, assumed))
                    fail("not-eq", b.l.pos);
                tc(b.r, l);
                return finish(b, tBool, exp);
            }
        case Tk.andAnd, Tk.orOr:
            tc(b.l, tBool);
            tc(b.r, tBool);
            return finish(b, tBool, exp);
        default:
            assert(0);
        }
    }

    private Type unary(Unary u, Type exp)
    {
        switch (u.op)
        {
        case Tk.minus:
            {
                auto t = prune(tc(u.e, null));
                if (t.k != TK.int_ && t.k != TK.float_)
                    fail("type-mismatch", u.e.pos);
                return finish(u, t, exp);
            }
        case Tk.bang:
            tc(u.e, tBool);
            return finish(u, tBool, exp);
        case Tk.tilde:
            tc(u.e, tInt);
            return finish(u, tInt, exp);
        default:
            assert(0);
        }
    }

    private Type indexExpr(IndexExpr ix, Type exp)
    {
        auto a = prune(tc(ix.base, null));
        Type r;
        if (a.k == TK.list)
        {
            tc(ix.index, tInt);
            r = a.args[0];
        }
        else if (a.k == TK.str)
        {
            tc(ix.index, tInt);
            r = tChar;
        }
        else if (a.k == TK.map)
        {
            tc(ix.index, a.args[0]);
            r = a.args[1];
        }
        else
            fail("not-indexable", ix.base.pos);
        return finish(ix, r, exp);
    }

    private Type fieldExpr(FieldExpr f, Type exp)
    {
        auto t = prune(tc(f.base, null));
        if (t.k != TK.named || t.decl.isEnum)
            fail("not-struct", f.base.pos);
        int idx = t.decl.fieldIndex(f.name);
        if (idx < 0)
            fail("unknown-field", f.namePos);
        f.fieldIdx = idx;
        return finish(f, subst(t.decl.fields[idx].ty, t.decl.tparams, t.args), exp);
    }

    // ---- structs

    private Type structLit(StructLit s, Type exp)
    {
        auto d = lookupTypeDecl(w, mod, s.qual, s.qualPos, s.name, s.namePos);
        if (d is null)
        {
            bool known = isTypeName(s.name);
            foreach (tp; sc.tparams)
                if (tp.name == s.name)
                    known = true;
            if (known)
                fail("not-struct", s.pos);
            fail("unknown-type", s.namePos);
        }
        if (d.isEnum)
            fail("not-struct", s.pos);
        s.decl = d;
        beginOwner();
        Type[] vs;
        foreach (_; d.tparams)
            vs ~= fresh();
        auto st = namedOf(d, vs);
        if (exp !is null && !unify(exp, st))
            fail("type-mismatch", s.pos);
        bool[string] seen;
        foreach (fi; s.inits)
        {
            if (fi.name in seen)
                fail("dup-field", fi.pos);
            seen[fi.name] = true;
            if (d.fieldIndex(fi.name) < 0)
                fail("unknown-field", fi.pos);
        }
        s.declToInit = new int[d.fields.length];
        foreach (i, fld; d.fields)
        {
            int found = -1;
            foreach (j, fi; s.inits)
                if (fi.name == fld.name)
                    found = cast(int) j;
            if (found < 0)
                fail("missing-field", s.pos);
            s.declToInit[i] = found;
            tc(s.inits[found].value, subst(fld.ty, d.tparams, vs));
        }
        endOwner(s.pos);
        s.ty = zonk(st);
        return s.ty;
    }

    // ---- literals

    private Type expandVar(Type t, Pos pos, TK want, Type[] parts)
    {
        // t is an unsolved variable: solve it to a type of form `want` with the given parts
        auto nt = new Type(want, parts);
        t.link = nt;
        return nt;
    }

    private Type listLit(ListLit l, Type exp)
    {
        if (exp !is null)
        {
            auto t = prune(exp);
            if (t.k == TK.var)
                t = expandVar(t, l.pos, TK.list, [fresh()]);
            if (t.k != TK.list)
                fail("type-mismatch", l.pos);
            foreach (e; l.elems)
                tc(e, t.args[0]);
            l.ty = t;
            return t;
        }
        if (l.elems.length == 0)
            fail("cannot-infer", l.pos);
        auto et = tc(l.elems[0], null);
        foreach (e; l.elems[1 .. $])
            tc(e, et);
        l.ty = listOf(et);
        return l.ty;
    }

    private Type mapLit(MapLit m, Type exp)
    {
        if (exp !is null)
        {
            auto t = prune(exp);
            if (t.k == TK.var)
            {
                auto k = fresh();
                auto v = fresh();
                t = expandVar(t, m.pos, TK.map, [k, v]);
                if (deferred.length)
                    deferred[$ - 1] ~= DeferredKey(k, m.pos);
            }
            if (t.k != TK.map)
                fail("type-mismatch", m.pos);
            foreach (i; 0 .. m.keys.length)
            {
                tc(m.keys[i], t.args[0]);
                tc(m.vals[i], t.args[1]);
            }
            if (isGround(t.args[0]) && !holdsKey(w, t.args[0]))
                fail("bad-key-type", m.pos);
            m.ty = t;
            return t;
        }
        if (m.keys.length == 0)
            fail("cannot-infer", m.pos);
        auto k = tc(m.keys[0], null);
        if (!holdsKey(w, k))
            fail("bad-key-type", m.keys[0].pos);
        auto v = tc(m.vals[0], null);
        foreach (i; 1 .. m.keys.length)
        {
            tc(m.keys[i], k);
            tc(m.vals[i], v);
        }
        m.ty = mapOf(k, v);
        return m.ty;
    }

    private Type tupleLit(TupleLit t, Type exp)
    {
        if (t.elems.length > 8)
            fail("bad-arity", t.pos);
        if (exp !is null)
        {
            auto et = prune(exp);
            if (et.k == TK.var)
            {
                Type[] parts;
                foreach (_; t.elems)
                    parts ~= fresh();
                et = expandVar(et, t.pos, TK.tuple, parts);
            }
            if (et.k != TK.tuple || et.args.length != t.elems.length)
                fail("type-mismatch", t.pos);
            foreach (i, e; t.elems)
                tc(e, et.args[i]);
            t.ty = et;
            return et;
        }
        Type[] parts;
        foreach (e; t.elems)
            parts ~= tc(e, null);
        t.ty = new Type(TK.tuple, parts);
        return t.ty;
    }

    // ---- lambdas

    private Type lambda(Lambda l, Type exp)
    {
        Type[] ptypes;
        Type ret;
        Type fnType;
        if (exp !is null)
        {
            auto t = prune(exp);
            if (t.k == TK.var)
            {
                Type[] parts;
                foreach (_; l.params)
                    parts ~= fresh();
                parts ~= fresh();
                t = expandVar(t, l.pos, TK.fn, parts);
            }
            if (t.k != TK.fn || fnParams(t).length != l.params.length)
                fail("type-mismatch", l.pos);
            fnType = t;
            foreach (i, ref p; l.params)
            {
                auto ai = fnParams(t)[i];
                if (p.te !is null)
                {
                    auto a = resolveType(w, sc, p.te);
                    if (!unify(ai, a))
                        fail("type-mismatch", p.te.pos);
                }
                else if (!isGround(ai) && prune(ai).k == TK.var)
                    fail("cannot-infer", p.pos);
                ptypes ~= ai;
            }
            ret = fnRet(t);
            if (l.retTe !is null)
            {
                auto dr = resolveType(w, sc, l.retTe);
                if (!unify(ret, dr))
                    fail("type-mismatch", l.retTe.pos);
            }
        }
        else
        {
            foreach (ref p; l.params)
            {
                if (p.te is null)
                    fail("cannot-infer", p.pos);
                ptypes ~= resolveType(w, sc, p.te);
            }
            if (l.retTe !is null)
                ret = resolveType(w, sc, l.retTe);
        }
        // duplicate parameter names
        foreach (i, ref p; l.params)
            foreach (j; 0 .. i)
                if (l.params[j].name == p.name)
                    fail("dup-name", p.pos);
        auto info = new FuncInfo;
        info.parent = ctx.info;
        l.info = info;
        auto saved = ctx;
        ctx = new FuncCtx;
        ctx.info = info;
        ctx.parent = saved;
        ctx.ret = ret; // null in synthesis mode without `->`
        pushScope();
        foreach (i, ref p; l.params)
        {
            p.var = newVar(p.name, ptypes[i], false, p.pos);
            declare(p.var);
        }
        if (ret !is null)
            checkBody(l.body, ret, l.pos);
        else
        {
            // synthesis: the body's type is the lambda's return type
            Type r;
            if (auto b = cast(Block) l.body)
            {
                pushScope();
                foreach (s; b.stmts)
                    checkStmt(s);
                r = b.trailing !is null ? tc(b.trailing, null) : tUnit;
                b.ty = r;
                popScope();
            }
            else
                r = tc(l.body, null);
            ret = r;
        }
        popScope();
        ctx = saved;
        if (fnType is null)
            fnType = fnOf(ptypes, ret);
        l.ty = fnType;
        return fnType;
    }

    // ---- control flow expressions

    private Type blockExpr(Block b, Type exp)
    {
        pushScope();
        foreach (s; b.stmts)
            checkStmt(s);
        Type r;
        if (b.trailing !is null)
            r = tc(b.trailing, exp);
        else if (exp !is null)
        {
            if (!diverges(b) && !unify(exp, tUnit))
                fail("type-mismatch", b.pos);
            r = exp;
        }
        else
            r = tUnit;
        popScope();
        b.ty = r;
        return r;
    }

    private Type ifExpr(IfExpr i, Type exp)
    {
        tc(i.cond, tBool);
        if (i.els is null)
        {
            if (exp !is null && !unify(exp, tUnit))
                fail("type-mismatch", i.pos);
            tc(i.then, tUnit);
            i.ty = tUnit;
            return tUnit;
        }
        if (exp !is null)
        {
            tc(i.then, exp);
            tc(i.els, exp);
            i.ty = exp;
            return exp;
        }
        Type r;
        if (!diverges(i.then))
        {
            r = tc(i.then, null);
            tc(i.els, r);
        }
        else
        {
            tc(i.then, null);
            if (diverges(i.els))
            {
                tc(i.els, null);
                r = tUnit;
            }
            else
                r = tc(i.els, null);
        }
        i.ty = r;
        return r;
    }

    private Type matchExpr(MatchExpr m, Type exp)
    {
        auto s = tc(m.scrut, null);
        if (m.arms.length == 0)
            fail("non-exhaustive", m.pos);
        Type r = exp;
        foreach (arm; m.arms)
        {
            pushScope();
            PatEnv env;
            checkPat(arm.pat, s, env);
            foreach (b; env.bindings)
                declare(b);
            if (arm.guard !is null)
                tc(arm.guard, tBool);
            if (exp !is null)
                tc(arm.body, exp);
            else if (r is null)
            {
                if (!diverges(arm.body))
                    r = tc(arm.body, null);
                else
                    tc(arm.body, null);
            }
            else
                tc(arm.body, r);
            popScope();
        }
        auto an = analyseMatch(zonk(s), m.arms);
        if (an.unreachableArm >= 0)
            fail("unreachable", m.arms[an.unreachableArm].pat.pos);
        if (!an.exhaustive)
            fail("non-exhaustive", m.pos);
        if (r is null)
            r = tUnit;
        m.ty = r;
        return r;
    }

    // ------------------------------------------------------------ patterns

    private void addBinding(ref PatEnv env, string name, Type t, Pos pos, out LocalVar lv)
    {
        foreach (b; env.bindings)
            if (b.name == name)
                fail("dup-name", pos);
        lv = newVar(name, t, false, pos);
        env.bindings ~= lv;
    }

    private void checkVariantTyping(Pat p, ValueItem vi, Type t, Pat[] subs, ref PatEnv env)
    {
        if (vi is null || vi.kind != ValueItem.Kind.variant)
            fail("type-mismatch", p.pos);
        t = prune(t);
        if (t.k != TK.named || t.decl !is vi.enumDecl)
            fail("type-mismatch", p.pos);
        auto payload = vi.enumDecl.variants[vi.variantIdx].payload;
        if (subs.length != payload.length)
            fail("arity", p.pos);
        foreach (i, s; subs)
            checkPat(s, subst(payload[i], vi.enumDecl.tparams, t.args), env);
    }

    private void checkPat(Pat p, Type t, ref PatEnv env)
    {
        t = prune(t);
        if (cast(WildPat) p)
            return;
        if (auto ip = cast(IdentPat) p)
        {
            ValueItem vi;
            if (!ip.forceBind)
            {
                if (auto pv = ip.name in mod.values)
                    vi = *pv;
                else if (auto pv = ip.name in w.prelude.values)
                    vi = *pv;
                if (vi !is null && !(vi.kind == ValueItem.Kind.variant
                        && vi.enumDecl.variants[vi.variantIdx].payload.length == 0))
                    vi = null;
            }
            if (vi !is null)
            {
                ip.enumDecl = vi.enumDecl;
                ip.variantIdx = vi.variantIdx;
                checkVariantTyping(p, vi, t, null, env);
            }
            else
                addBinding(env, ip.name, t, ip.pos, ip.var);
            return;
        }
        if (auto lp = cast(LitPat) p)
        {
            Type lt;
            final switch (lp.kind)
            {
            case LitPat.Kind.float_:
                fail("bad-pattern", p.pos);
            case LitPat.Kind.int_:
                lt = tInt;
                break;
            case LitPat.Kind.str:
                lt = tStr;
                break;
            case LitPat.Kind.char_:
                lt = tChar;
                break;
            case LitPat.Kind.bool_:
                lt = tBool;
                break;
            }
            if (!typeEq(lt, t))
                fail("type-mismatch", p.pos);
            return;
        }
        if (auto tp = cast(TuplePat) p)
        {
            if (t.k != TK.tuple || t.args.length != tp.subs.length)
                fail("type-mismatch", p.pos);
            foreach (i, s; tp.subs)
                checkPat(s, t.args[i], env);
            return;
        }
        if (auto lp = cast(ListPat) p)
        {
            if (t.k != TK.list)
                fail("type-mismatch", p.pos);
            foreach (s; lp.subs)
                checkPat(s, t.args[0], env);
            if (lp.restName.length)
                addBinding(env, lp.restName, t, lp.restPos, lp.restVar);
            return;
        }
        if (auto sp = cast(StructPat) p)
        {
            auto d = lookupTypeDecl(w, mod, sp.qual, sp.qualPos, sp.name, sp.namePos);
            if (d is null)
            {
                bool known = isTypeName(sp.name);
                foreach (tp; sc.tparams)
                    if (tp.name == sp.name)
                        known = true;
                if (known)
                    fail("not-struct", p.pos);
                fail("unknown-type", sp.namePos);
            }
            if (d.isEnum)
                fail("not-struct", p.pos);
            if (t.k != TK.named || t.decl !is d)
                fail("type-mismatch", p.pos);
            sp.decl = d;
            bool[string] seen;
            foreach (ref fp; sp.fields)
            {
                if (fp.name in seen)
                    fail("dup-field", fp.pos);
                seen[fp.name] = true;
                int idx = d.fieldIndex(fp.name);
                if (idx < 0)
                    fail("unknown-field", fp.pos);
                fp.fieldIdx = idx;
            }
            if (!sp.dots)
                foreach (fl; d.fields)
                    if (fl.name !in seen)
                        fail("missing-field", p.pos);
            foreach (ref fp; sp.fields)
                checkPat(fp.sub, subst(d.fields[fp.fieldIdx].ty, d.tparams, t.args), env);
            return;
        }
        if (auto vp = cast(VariantPat) p)
        {
            TraitDecl tr;
            int mi;
            auto vi = lookupValueItem(vp.qual, vp.qualPos, vp.name, vp.namePos, tr, mi);
            if (vi is null && tr is null)
                fail("unknown-name", vp.namePos);
            if (vi !is null && vi.kind == ValueItem.Kind.variant)
            {
                vp.enumDecl = vi.enumDecl;
                vp.variantIdx = vi.variantIdx;
            }
            checkVariantTyping(p, vi, t, vp.subs, env);
            return;
        }
        assert(0);
    }

    private bool irrefutable(Pat p)
    {
        if (cast(WildPat) p)
            return true;
        if (auto ip = cast(IdentPat) p)
        {
            if (ip.enumDecl is null)
                return true;
            return ip.enumDecl.variants.length == 1;
        }
        if (cast(LitPat) p)
            return false;
        if (auto tp = cast(TuplePat) p)
        {
            foreach (s; tp.subs)
                if (!irrefutable(s))
                    return false;
            return true;
        }
        if (auto lp = cast(ListPat) p)
            return lp.subs.length == 0 && lp.hasRest;
        if (auto sp = cast(StructPat) p)
        {
            foreach (fp; sp.fields)
                if (!irrefutable(fp.sub))
                    return false;
            return true;
        }
        if (auto vp = cast(VariantPat) p)
        {
            if (vp.enumDecl.variants.length != 1)
                return false;
            foreach (s; vp.subs)
                if (!irrefutable(s))
                    return false;
            return true;
        }
        return false;
    }
}

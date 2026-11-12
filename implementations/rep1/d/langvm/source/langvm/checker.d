/// The type checker: pass 4 of SPEC.md section 13.2 (sections 8 to 12).
///
/// Checking is local and bidirectional (`infer` / `check`). Besides finding
/// the first error, the checker annotates the syntax tree with everything the
/// bytecode compiler needs (resolved items, variables, closure captures).
module langvm.checker;

import langvm.ast;
import langvm.bounds;
import langvm.diag;
import langvm.patterns;
import langvm.symbols;
import langvm.types;

/// A lexical scope of local variables.
private final class Scope
{
    Scope parent;
    LocalVar[string] vars;

    this(Scope parent)
    {
        this.parent = parent;
    }
}

/// Check every function body of the program, in the order of SPEC.md section 13.2.
/// Returns the checked bodies (user functions, impl methods, default methods).
FnInfo[] checkProgram(World w)
{
    auto c = new Checker(w);
    c.checkAll();
    return c.bodies;
}

private final class Checker
{
    World w;
    ModInfo mod;
    TypeEnv env;
    FuncCtx fctx;
    Scope sc;
    Type[][] owners;
    FnInfo[] bodies;

    this(World w)
    {
        this.w = w;
    }

    // ------------------------------------------------------------ driver

    void checkAll()
    {
        foreach (m; w.mods)
        {
            mod = m;
            foreach (it; m.items)
            {
                switch (it.kind)
                {
                case IK.fn:
                    checkFn((cast(FnDecl) it).info);
                    break;
                case IK.trait:
                    foreach (md; (cast(TraitDecl) it).methods)
                        if (md.body !is null)
                            checkFn(md.info);
                    break;
                case IK.impl:
                    foreach (md; (cast(ImplDecl) it).methods)
                        checkFn(md.info);
                    break;
                default:
                    break;
                }
            }
        }
    }

    void checkFn(FnInfo fi)
    {
        auto decl = fi.decl;
        env = TypeEnv(mod, fi.tpScope, fi.selfType);
        auto ctx = new FuncCtx();
        ctx.ret = fi.ret;
        fctx = ctx;
        sc = new Scope(null);
        owners = null;
        size_t pi = 0;
        if (decl.hasSelf)
        {
            auto sv = declareVar("self", fi.params[0], false);
            decl.paramVars ~= sv;
            pi = 1;
        }
        foreach (i, p; decl.params)
        {
            auto v = declareVar(p.name, fi.params[pi + i], false);
            decl.paramVars ~= v;
        }
        decl.ctx = ctx;
        checkBodyBlock(decl.body, fi.ret, decl.pos);
        bodies ~= fi;
    }

    // ------------------------------------------------------------ scopes and variables

    void pushScope()
    {
        sc = new Scope(sc);
    }

    void popScope()
    {
        sc = sc.parent;
    }

    LocalVar declareVar(string name, Type t, bool mutable)
    {
        auto v = new LocalVar();
        v.name = name;
        v.type = t;
        v.mutable = mutable;
        v.owner = fctx;
        sc.vars[name] = v;
        return v;
    }

    LocalVar newVarObj(string name, Type t)
    {
        auto v = new LocalVar();
        v.name = name;
        v.type = t;
        v.owner = fctx;
        return v;
    }

    LocalVar lookupLocal(string name)
    {
        for (auto s = sc; s !is null; s = s.parent)
            if (auto p = name in s.vars)
                return *p;
        return null;
    }

    /// Record that the current function reads `v`, capturing it through every
    /// lambda between here and the function that binds it.
    void noteUse(LocalVar v)
    {
        for (auto c = fctx; c !is null && c !is v.owner; c = c.parent)
            if (c.captureIndex(v) < 0)
                c.captures ~= v;
    }

    // ------------------------------------------------------------ inference variables

    Type freshVar()
    {
        auto v = newVar();
        if (owners.length)
            owners[$ - 1] ~= v;
        return v;
    }

    void beginOwner()
    {
        owners ~= cast(Type[]) null;
    }

    Type[] endOwner()
    {
        auto r = owners[$ - 1];
        owners.length = owners.length - 1;
        return r;
    }

    static CompileError mismatch(Pos p)
    {
        return err(Kind.typeMismatch, p);
    }

    /// If `t` is an unsolved variable, solve it to the shape `mk(fresh...)`; return the pruned type.
    Type expandList(Type t)
    {
        t = prune(t);
        if (t.kind == TK.var)
        {
            auto s = mkList(freshVar());
            t.link = s;
            return s;
        }
        return t;
    }

    // ------------------------------------------------------------ divergence (11.6)

    static bool diverges(Expr e)
    {
        switch (e.kind)
        {
        case EK.block:
        {
            auto b = cast(BlockExpr) e;
            foreach (s; b.stmts)
                if (stmtDiverges(s))
                    return true;
            return b.tail !is null && diverges(b.tail);
        }
        case EK.if_:
        {
            auto i = cast(IfExpr) e;
            return i.else_ !is null && diverges(i.then) && diverges(i.else_);
        }
        case EK.match:
        {
            auto m = cast(MatchExpr) e;
            if (m.arms.length == 0)
                return false;
            foreach (a; m.arms)
                if (!diverges(a.body))
                    return false;
            return true;
        }
        default:
            return false;
        }
    }

    static bool stmtDiverges(Stmt s)
    {
        switch (s.kind)
        {
        case SK.return_, SK.break_, SK.continue_:
            return true;
        case SK.let_, SK.var_, SK.assign, SK.expr:
            return s.expr !is null && diverges(s.expr);
        default:
            return false;
        }
    }

    // ------------------------------------------------------------ bodies and blocks

    /// A function, method or lambda body whose value must have type `ret` (11.6).
    void checkBodyBlock(BlockExpr b, Type ret, Pos missingPos)
    {
        pushScope();
        foreach (s; b.stmts)
            checkStmt(s);
        if (b.tail !is null)
            check(b.tail, ret);
        else if (prune(ret).kind != TK.unit && !diverges(b))
            throw err(Kind.missingReturn, missingPos);
        popScope();
    }

    Type inferBlock(BlockExpr b)
    {
        pushScope();
        foreach (s; b.stmts)
            checkStmt(s);
        Type r = tUnit;
        if (b.tail !is null)
            r = infer(b.tail);
        popScope();
        return r;
    }

    void checkBlock(BlockExpr b, Type t)
    {
        pushScope();
        foreach (s; b.stmts)
            checkStmt(s);
        if (b.tail !is null)
            check(b.tail, t);
        else if (!diverges(b) && !unify(t, tUnit))
            throw mismatch(b.pos);
        popScope();
    }

    /// A `while`/`for` body: trailing expression is synthesised and discarded.
    void checkStmtBlock(BlockExpr b)
    {
        pushScope();
        foreach (s; b.stmts)
            checkStmt(s);
        if (b.tail !is null)
            infer(b.tail);
        popScope();
    }

    // ------------------------------------------------------------ statements

    void checkStmt(Stmt s)
    {
        final switch (s.kind)
        {
        case SK.let_:
        {
            Type t;
            if (s.ann !is null)
            {
                t = resolveType(w, s.ann, env);
                check(s.expr, t);
            }
            else
                t = infer(s.expr);
            Binder b;
            checkPat(s.pat, t, b);
            if (!irrefutable(s.pat))
                throw err(Kind.refutablePattern, s.pat.pos);
            foreach (v; b.vars)
                sc.vars[v.name] = v;
            break;
        }
        case SK.var_:
        {
            Type t;
            if (s.ann !is null)
            {
                t = resolveType(w, s.ann, env);
                check(s.expr, t);
            }
            else
                t = infer(s.expr);
            s.var = declareVar(s.name, t, true);
            break;
        }
        case SK.assign:
            checkAssign(s);
            break;
        case SK.expr:
            infer(s.expr);
            break;
        case SK.while_:
            check(s.expr, tBool);
            fctx.loopDepth++;
            checkStmtBlock(s.body);
            fctx.loopDepth--;
            break;
        case SK.for_:
            checkFor(s);
            break;
        case SK.return_:
            checkReturn(s);
            break;
        case SK.break_, SK.continue_:
            if (fctx.loopDepth == 0)
                throw err(Kind.breakOutside, s.pos);
            break;
        }
    }

    void checkFor(Stmt s)
    {
        Type elem;
        if (s.hi !is null)
        {
            check(s.expr, tInt);
            check(s.hi, tInt);
            elem = tInt;
            s.forKind = 2;
        }
        else
        {
            auto st = prune(infer(s.expr));
            if (st.kind == TK.list)
            {
                elem = st.args[0];
                s.forKind = 0;
            }
            else if (st.kind == TK.str)
            {
                elem = tChar;
                s.forKind = 1;
            }
            else
                throw err(Kind.notIterable, s.expr.pos);
        }
        Binder b;
        checkPat(s.pat, elem, b);
        if (!irrefutable(s.pat))
            throw err(Kind.refutablePattern, s.pat.pos);
        pushScope();
        foreach (v; b.vars)
            sc.vars[v.name] = v;
        fctx.loopDepth++;
        checkStmtBlock(s.body);
        fctx.loopDepth--;
        popScope();
    }

    void checkReturn(Stmt s)
    {
        if (fctx.ret is null)
            throw err(Kind.cannotInfer, s.pos);
        if (s.expr is null)
        {
            if (!unify(fctx.ret, tUnit))
                throw mismatch(s.pos);
            return;
        }
        if (prune(fctx.ret).kind == TK.unit)
        {
            auto t = prune(infer(s.expr));
            if (t.kind != TK.unit)
                throw mismatch(s.pos);
            return;
        }
        check(s.expr, fctx.ret);
    }

    void checkAssign(Stmt s)
    {
        auto tg = s.target;
        if (tg.kind == EK.path && (cast(PathExpr) tg).qual.length == 0)
        {
            auto p = cast(PathExpr) tg;
            auto v = lookupLocal(p.name);
            if (v is null)
                throw err(Kind.unknownName, p.namePos);
            if (!v.mutable)
                throw err(Kind.assignImmutable, p.namePos);
            if (v.owner !is fctx)
                throw err(Kind.assignCaptured, p.namePos);
            s.var = v;
            check(s.expr, v.type);
            return;
        }
        if (tg.kind == EK.index)
        {
            auto ix = cast(IndexExpr) tg;
            auto a = prune(infer(ix.obj));
            if (a.kind == TK.list)
            {
                check(ix.idx, tInt);
                check(s.expr, a.args[0]);
            }
            else if (a.kind == TK.map)
            {
                check(ix.idx, a.args[0]);
                check(s.expr, a.args[1]);
            }
            else
                throw err(Kind.badTarget, ix.obj.pos);
            return;
        }
        throw err(Kind.badTarget, tg.pos);
    }

    // ------------------------------------------------------------ patterns

    struct Binder
    {
        LocalVar[] vars;
    }

    LocalVar bind(ref Binder b, string name, Pos pos, Type t)
    {
        foreach (v; b.vars)
            if (v.name == name)
                throw err(Kind.dupName, pos);
        auto v = newVarObj(name, t);
        b.vars ~= v;
        return v;
    }

    /// Resolve the declaration named by a struct literal / struct pattern path.
    /// Returns null when the path names something that is not a struct or enum.
    TypeDecl lookupDecl(string qual, Pos qualPos, string name, Pos namePos, Pos first)
    {
        if (qual.length == 0)
        {
            if (auto p = name in env.tparams)
                return null;
            if (name == "Self")
            {
                if (env.selfType is null)
                    throw err(Kind.selfOutside, first);
                auto st = prune(env.selfType);
                return st.kind == TK.named ? st.decl : null;
            }
            switch (name)
            {
            case "Int", "Float", "Bool", "Char", "Str", "Unit":
                return null;
            default:
                break;
            }
            if (auto p = name in mod.types)
                return *p;
            if (auto p = name in w.prelude.types)
                return *p;
            throw err(Kind.unknownType, namePos);
        }
        auto mp = qual in mod.imports;
        if (mp is null)
            throw err(Kind.unknownModule, qualPos);
        auto m = w.mods[*mp];
        auto p = name in m.types;
        if (p is null)
            throw err(Kind.unknownType, namePos);
        if (!p.pub && m !is mod)
            throw err(Kind.notPublic, namePos);
        return *p;
    }

    void checkPat(Pattern p, Type t0, ref Binder b)
    {
        auto t = prune(t0);
        if (p.kind == PatK.bind)
        {
            auto item = w.lookupValue(mod, p.name);
            if (item !is null && item.variant !is null && item.variant.payload.length == 0)
            {
                p.kind = PatK.variant;
                p.variant = item.variant;
                p.cname = p.name;
                p.cnamePos = p.pos;
            }
        }
        final switch (p.kind)
        {
        case PatK.wild:
            return;
        case PatK.bind:
            p.var = bind(b, p.name, p.pos, t);
            return;
        case PatK.float_:
            throw err(Kind.badPattern, p.pos);
        case PatK.int_:
            if (t.kind != TK.int_)
                throw mismatch(p.pos);
            return;
        case PatK.char_:
            if (t.kind != TK.char_)
                throw mismatch(p.pos);
            return;
        case PatK.str:
            if (t.kind != TK.str)
                throw mismatch(p.pos);
            return;
        case PatK.bool_:
            if (t.kind != TK.bool_)
                throw mismatch(p.pos);
            return;
        case PatK.tuple:
            if (t.kind != TK.tuple || t.args.length != p.subs.length)
                throw mismatch(p.pos);
            foreach (i, sp; p.subs)
                checkPat(sp, t.args[i], b);
            return;
        case PatK.list:
        {
            if (t.kind != TK.list)
                throw mismatch(p.pos);
            auto elem = t.args[0];
            foreach (sp; p.subs)
                checkPat(sp, elem, b);
            if (p.restName.length)
                p.restVar = bind(b, p.restName, p.restPos, t);
            return;
        }
        case PatK.variant:
            checkVariantPat(p, t, b);
            return;
        case PatK.struct_:
            checkStructPat(p, t, b);
            return;
        }
    }

    void checkVariantPat(Pattern p, Type t, ref Binder b)
    {
        if (p.variant is null)
        {
            ValueItem item;
            if (p.qual.length == 0)
            {
                item = w.lookupValue(mod, p.cname);
                if (item is null)
                    throw err(Kind.unknownName, p.cnamePos);
            }
            else
            {
                auto mp = p.qual in mod.imports;
                if (mp is null)
                {
                    if (w.traitByName(mod, p.qual) !is null)
                        throw mismatch(p.pos);
                    throw err(Kind.unknownModule, p.qualPos);
                }
                auto m = w.mods[*mp];
                auto ip = p.cname in m.values;
                if (ip is null)
                    throw err(Kind.unknownName, p.cnamePos);
                if (!pubFn(*ip) && m !is mod)
                    throw err(Kind.notPublic, p.cnamePos);
                item = *ip;
            }
            if (item.variant is null)
                throw mismatch(p.pos);
            p.variant = item.variant;
        }
        auto v = p.variant;
        if (t.kind != TK.named || t.decl !is v.decl)
            throw mismatch(p.pos);
        if (p.subs.length != v.payload.length)
            throw err(Kind.arity, p.pos);
        foreach (i, sp; p.subs)
            checkPat(sp, subst(v.payload[i], v.decl.tparams, t.args), b);
    }

    static bool pubFn(ValueItem it)
    {
        return it.fn !is null ? it.fn.pub : it.variant.decl.pub;
    }

    void checkStructPat(Pattern p, Type t, ref Binder b)
    {
        auto d = lookupDecl(p.qual, p.qualPos, p.cname, p.cnamePos, p.pos);
        if (d is null || d.isEnum)
            throw err(Kind.notStruct, p.pos);
        if (t.kind != TK.named || t.decl !is d)
            throw mismatch(p.pos);
        p.decl = d;
        foreach (i, ref f; p.fields)
        {
            foreach (j; 0 .. i)
                if (p.fields[j].name == f.name)
                    throw err(Kind.dupField, f.pos);
            f.fieldIdx = d.fieldIndex(f.name);
            if (f.fieldIdx < 0)
                throw err(Kind.unknownField, f.pos);
        }
        if (!p.structRest)
        {
            foreach (i, fl; d.fields)
            {
                bool seen = false;
                foreach (f; p.fields)
                    seen |= f.fieldIdx == cast(int) i;
                if (!seen)
                    throw err(Kind.missingField, p.pos);
            }
        }
        foreach (ref f; p.fields)
        {
            auto ft = subst(d.fields[f.fieldIdx].type, d.tparams, t.args);
            if (f.pat !is null)
                checkPat(f.pat, ft, b);
            else
                f.var = bind(b, f.name, f.pos, ft);
        }
    }

    /// 12.6: does the (typed) pattern match every value of its type?
    static bool irrefutable(Pattern p)
    {
        final switch (p.kind)
        {
        case PatK.wild, PatK.bind:
            return true;
        case PatK.int_, PatK.float_, PatK.str, PatK.char_, PatK.bool_:
            return false;
        case PatK.tuple:
            foreach (s; p.subs)
                if (!irrefutable(s))
                    return false;
            return true;
        case PatK.struct_:
            foreach (f; p.fields)
                if (f.pat !is null && !irrefutable(f.pat))
                    return false;
            return true;
        case PatK.variant:
            if (p.variant.decl.variants.length != 1)
                return false;
            foreach (s; p.subs)
                if (!irrefutable(s))
                    return false;
            return true;
        case PatK.list:
            return p.subs.length == 0 && p.hasRest;
        }
    }

    // ------------------------------------------------------------ expressions: check

    void check(Expr e, Type t)
    {
        switch (e.kind)
        {
        case EK.list:
            checkList(cast(SeqExpr) e, t);
            return;
        case EK.map:
            checkMap(cast(SeqExpr) e, t);
            return;
        case EK.tuple:
            checkTuple(cast(SeqExpr) e, t);
            return;
        case EK.lambda:
            checkLambda(cast(LambdaExpr) e, t);
            return;
        case EK.if_:
            checkIf(cast(IfExpr) e, t);
            return;
        case EK.match:
            checkMatch(cast(MatchExpr) e, t);
            return;
        case EK.block:
            checkBlock(cast(BlockExpr) e, t);
            return;
        case EK.call:
            inferCall(cast(CallExpr) e, t);
            return;
        case EK.path:
            inferPath(cast(PathExpr) e, t);
            return;
        case EK.structLit:
            inferStructLit(cast(StructLitExpr) e, t);
            return;
        default:
            auto s = infer(e);
            if (!unify(t, s))
                throw mismatch(e.pos);
            return;
        }
    }

    void checkList(SeqExpr e, Type t)
    {
        auto lt = expandList(t);
        if (lt.kind != TK.list)
            throw mismatch(e.pos);
        foreach (x; e.elems)
            check(x, lt.args[0]);
    }

    void checkMap(SeqExpr e, Type t)
    {
        auto mt = prune(t);
        bool fresh = false;
        if (mt.kind == TK.var)
        {
            auto s = mkMap(freshVar(), freshVar());
            mt.link = s;
            mt = s;
            fresh = true;
        }
        if (mt.kind != TK.map)
            throw mismatch(e.pos);
        for (size_t i = 0; i < e.elems.length; i += 2)
        {
            check(e.elems[i], mt.args[0]);
            check(e.elems[i + 1], mt.args[1]);
        }
        if (fresh && !hasUnsolved(mt.args[0]) && !holdsKey(mt.args[0]))
            throw err(Kind.badKeyType, e.pos);
    }

    void checkTuple(SeqExpr e, Type t)
    {
        if (e.elems.length > 8)
            throw err(Kind.badArity, e.pos);
        auto tt = prune(t);
        if (tt.kind == TK.var)
        {
            Type[] cs;
            foreach (_; e.elems)
                cs ~= freshVar();
            auto s = mkTuple(cs);
            tt.link = s;
            tt = s;
        }
        if (tt.kind != TK.tuple || tt.args.length != e.elems.length)
            throw mismatch(e.pos);
        foreach (i, x; e.elems)
            check(x, tt.args[i]);
    }

    void checkIf(IfExpr e, Type t)
    {
        check(e.cond, tBool);
        if (e.else_ is null)
        {
            if (!unify(t, tUnit))
                throw mismatch(e.pos);
            check(e.then, tUnit);
            return;
        }
        check(e.then, t);
        check(e.else_, t);
    }

    void checkMatch(MatchExpr e, Type t)
    {
        auto s = matchHead(e);
        foreach (ref a; e.arms)
        {
            checkArm(a, s);
            check(a.body, t);
            popScope();
        }
        matchCoverage(e, s);
    }

    // ------------------------------------------------------------ expressions: infer

    Type infer(Expr e)
    {
        final switch (e.kind)
        {
        case EK.int_:
            return tInt;
        case EK.float_:
            return tFloat;
        case EK.str:
            return tStr;
        case EK.char_:
            return tChar;
        case EK.bool_:
            return tBool;
        case EK.self_:
        {
            auto v = lookupLocal("self");
            if (v is null)
                throw err(Kind.selfOutside, e.pos);
            noteUse(v);
            (cast(SelfExpr) e).var = v;
            return v.type;
        }
        case EK.path:
            return inferPath(cast(PathExpr) e, null);
        case EK.structLit:
            return inferStructLit(cast(StructLitExpr) e, null);
        case EK.tuple:
        {
            auto s = cast(SeqExpr) e;
            if (s.elems.length > 8)
                throw err(Kind.badArity, e.pos);
            Type[] cs;
            foreach (x; s.elems)
                cs ~= infer(x);
            return mkTuple(cs);
        }
        case EK.list:
        {
            auto s = cast(SeqExpr) e;
            if (s.elems.length == 0)
                throw err(Kind.cannotInfer, e.pos);
            auto t = infer(s.elems[0]);
            foreach (x; s.elems[1 .. $])
                check(x, t);
            return mkList(t);
        }
        case EK.map:
        {
            auto s = cast(SeqExpr) e;
            if (s.elems.length == 0)
                throw err(Kind.cannotInfer, e.pos);
            auto k = infer(s.elems[0]);
            if (!holdsKey(k))
                throw err(Kind.badKeyType, s.elems[0].pos);
            auto v = infer(s.elems[1]);
            for (size_t i = 2; i < s.elems.length; i += 2)
            {
                check(s.elems[i], k);
                check(s.elems[i + 1], v);
            }
            return mkMap(k, v);
        }
        case EK.lambda:
            return inferLambda(cast(LambdaExpr) e);
        case EK.if_:
            return inferIf(cast(IfExpr) e);
        case EK.match:
            return inferMatch(cast(MatchExpr) e);
        case EK.block:
            return inferBlock(cast(BlockExpr) e);
        case EK.unary:
            return inferUnary(cast(UnaryExpr) e);
        case EK.binary:
            return inferBinary(cast(BinaryExpr) e);
        case EK.call:
            return inferCall(cast(CallExpr) e, null);
        case EK.method:
            return inferMethod(cast(MethodExpr) e);
        case EK.index:
        {
            auto ix = cast(IndexExpr) e;
            auto a = prune(infer(ix.obj));
            switch (a.kind)
            {
            case TK.list:
                check(ix.idx, tInt);
                return a.args[0];
            case TK.str:
                check(ix.idx, tInt);
                return tChar;
            case TK.map:
                check(ix.idx, a.args[0]);
                return a.args[1];
            default:
                throw err(Kind.notIndexable, ix.obj.pos);
            }
        }
        case EK.field:
        {
            auto f = cast(FieldExpr) e;
            auto t = prune(infer(f.obj));
            if (t.kind != TK.named || t.decl.isEnum)
                throw err(Kind.notStruct, f.obj.pos);
            const idx = t.decl.fieldIndex(f.name);
            if (idx < 0)
                throw err(Kind.unknownField, f.namePos);
            f.fieldIdx = idx;
            return subst(t.decl.fields[idx].type, t.decl.tparams, t.args);
        }
        }
    }

    Type inferUnary(UnaryExpr e)
    {
        final switch (e.op)
        {
        case Operator.neg:
        {
            auto t = prune(infer(e.operand));
            if (t.kind != TK.int_ && t.kind != TK.float_)
                throw mismatch(e.operand.pos);
            e.isFloat = t.kind == TK.float_;
            return t;
        }
        case Operator.not:
            check(e.operand, tBool);
            return tBool;
        case Operator.bnot:
            check(e.operand, tInt);
            return tInt;
        case Operator.add, Operator.sub, Operator.mul, Operator.div, Operator.rem, Operator.concat, Operator.band, Operator.bor, Operator.bxor,
            Operator.shl, Operator.shr, Operator.lt, Operator.le, Operator.gt, Operator.ge, Operator.eq, Operator.ne, Operator.and, Operator.or:
            assert(false);
        }
    }

    Type inferBinary(BinaryExpr e)
    {
        switch (e.op)
        {
        case Operator.add, Operator.sub, Operator.mul, Operator.div, Operator.rem:
        {
            auto l = prune(infer(e.left));
            if (l.kind != TK.int_ && l.kind != TK.float_)
                throw mismatch(e.left.pos);
            if (e.op == Operator.rem && l.kind != TK.int_)
                throw mismatch(e.left.pos);
            e.isFloat = l.kind == TK.float_;
            check(e.right, l);
            return l;
        }
        case Operator.concat:
        {
            auto l = prune(infer(e.left));
            if (l.kind != TK.str && l.kind != TK.list)
                throw mismatch(e.left.pos);
            e.isStr = l.kind == TK.str;
            check(e.right, l);
            return l;
        }
        case Operator.band, Operator.bor, Operator.bxor, Operator.shl, Operator.shr:
            check(e.left, tInt);
            check(e.right, tInt);
            return tInt;
        case Operator.lt, Operator.le, Operator.gt, Operator.ge:
        {
            auto l = infer(e.left);
            if (!holdsOrd(l))
                throw err(Kind.notOrd, e.left.pos);
            check(e.right, l);
            return tBool;
        }
        case Operator.eq, Operator.ne:
        {
            auto l = infer(e.left);
            if (!holdsEq(l))
                throw err(Kind.notEq, e.left.pos);
            check(e.right, l);
            return tBool;
        }
        case Operator.and, Operator.or:
            check(e.left, tBool);
            check(e.right, tBool);
            return tBool;
        default:
            assert(false);
        }
    }

    Type inferIf(IfExpr e)
    {
        check(e.cond, tBool);
        if (e.else_ is null)
        {
            check(e.then, tUnit);
            return tUnit;
        }
        if (!diverges(e.then))
        {
            auto t = infer(e.then);
            check(e.else_, t);
            return t;
        }
        infer(e.then);
        if (diverges(e.else_))
        {
            infer(e.else_);
            return tUnit;
        }
        return infer(e.else_);
    }

    /// Check the scrutinee and the arm count of a `match`; returns the scrutinee type.
    Type matchHead(MatchExpr e)
    {
        auto s = infer(e.scrut);
        if (e.arms.length == 0)
            throw err(Kind.nonExhaustive, e.pos);
        return s;
    }

    /// Check an arm's pattern and guard in a new scope (the caller checks the
    /// body and pops the scope).
    void checkArm(ref Arm a, Type s)
    {
        pushScope();
        Binder b;
        checkPat(a.pat, s, b);
        foreach (v; b.vars)
            sc.vars[v.name] = v;
        if (a.guard !is null)
            check(a.guard, tBool);
    }

    void matchCoverage(MatchExpr e, Type s)
    {
        Pattern[] pats;
        bool[] guarded;
        foreach (a; e.arms)
        {
            pats ~= a.pat;
            guarded ~= a.guard !is null;
        }
        const u = firstUnreachable(s, pats, guarded);
        if (u >= 0)
            throw err(Kind.unreachable, pats[u].pos);
        if (!isExhaustive(s, pats, guarded))
            throw err(Kind.nonExhaustive, e.pos);
    }

    Type inferMatch(MatchExpr e)
    {
        auto s = matchHead(e);
        Type r;
        foreach (ref a; e.arms)
        {
            checkArm(a, s);
            if (r is null)
            {
                if (diverges(a.body))
                    infer(a.body);
                else
                    r = infer(a.body);
            }
            else
                check(a.body, r);
            popScope();
        }
        matchCoverage(e, s);
        return r is null ? tUnit : r;
    }

    // ------------------------------------------------------------ lambdas

    Type inferLambda(LambdaExpr e)
    {
        Type[] ps;
        foreach (p; e.params)
        {
            if (p.ann is null)
                throw err(Kind.cannotInfer, p.pos);
            ps ~= resolveType(w, p.ann, env);
        }
        Type ret;
        if (e.retAnn !is null)
            ret = resolveType(w, e.retAnn, env);
        lambdaBody(e, ps, ret, true);
        auto ctx = e.ctx;
        return mkFn(ps, ctx.ret);
    }

    void checkLambda(LambdaExpr e, Type t)
    {
        auto ft = prune(t);
        if (ft.kind == TK.var)
        {
            Type[] cs;
            foreach (_; e.params)
                cs ~= freshVar();
            auto s = mkFn(cs, freshVar());
            ft.link = s;
            ft = s;
        }
        if (ft.kind != TK.fn || ft.args.length != e.params.length)
            throw mismatch(e.pos);
        Type[] ps;
        foreach (i, p; e.params)
        {
            auto ai = ft.args[i];
            if (p.ann !is null)
            {
                auto an = resolveType(w, p.ann, env);
                if (!unify(ai, an))
                    throw mismatch(p.ann.pos);
            }
            else if (prune(ai).kind == TK.var)
                throw err(Kind.cannotInfer, p.pos);
            ps ~= ai;
        }
        Type ret = ft.ret;
        if (e.retAnn !is null)
        {
            auto rt = resolveType(w, e.retAnn, env);
            if (!unify(ret, rt))
                throw mismatch(e.retAnn.pos);
        }
        lambdaBody(e, ps, ret, false);
    }

    /// Shared tail of lambda checking: duplicate parameter names, then the body.
    /// `ret` is the expected body type, or null when it must be synthesised.
    void lambdaBody(LambdaExpr e, Type[] ps, Type ret, bool synth)
    {
        foreach (i, p; e.params)
            foreach (j; 0 .. i)
                if (e.params[j].name == p.name)
                    throw err(Kind.dupName, p.pos);
        auto ctx = new FuncCtx();
        ctx.parent = fctx;
        ctx.ret = ret;
        e.ctx = ctx;
        auto savedCtx = fctx;
        auto savedScope = sc;
        fctx = ctx;
        sc = new Scope(sc);
        foreach (i, p; e.params)
            e.paramVars ~= declareVar(p.name, ps[i], false);
        if (ret !is null)
        {
            if (e.body.kind == EK.block)
                checkBodyBlock(cast(BlockExpr) e.body, ret, e.pos);
            else
                check(e.body, ret);
        }
        else
        {
            // synthesis without a declared return type
            if (e.body.kind == EK.block)
                ctx.ret = inferBlock(cast(BlockExpr) e.body); // `return` inside is cannot-infer: ctx.ret is null meanwhile
            else
                ctx.ret = infer(e.body);
        }
        fctx = savedCtx;
        sc = savedScope;
    }

    // ------------------------------------------------------------ paths

    /// Resolve a value path; fills in the annotation fields of `p`.
    void resolvePath(PathExpr p)
    {
        if (p.qual.length == 0)
        {
            if (auto v = lookupLocal(p.name))
            {
                noteUse(v);
                p.res = ResK.local;
                p.var = v;
                return;
            }
            auto item = w.lookupValue(mod, p.name);
            if (item !is null)
            {
                setItem(p, item);
                return;
            }
            if (w.isTypeName(mod, p.name))
                throw err(Kind.badValueRef, p.namePos);
            throw err(Kind.unknownName, p.namePos);
        }
        if (auto mp = p.qual in mod.imports)
        {
            auto m = w.mods[*mp];
            auto ip = p.name in m.values;
            if (ip is null)
                throw err(Kind.unknownName, p.namePos);
            if (!pubFn(*ip) && m !is mod)
                throw err(Kind.notPublic, p.namePos);
            setItem(p, *ip);
            return;
        }
        if (auto tr = w.traitByName(mod, p.qual))
        {
            const mi = tr.methodIndex(p.name);
            if (mi < 0)
                throw err(Kind.unknownName, p.namePos);
            p.res = ResK.methodPath;
            p.trait = tr;
            p.methodIdx = mi;
            return;
        }
        throw err(Kind.unknownModule, p.qualPos);
    }

    void setItem(PathExpr p, ValueItem item)
    {
        if (item.fn !is null)
        {
            p.res = ResK.fn;
            p.fn = item.fn;
        }
        else
        {
            p.res = ResK.variant;
            p.variant = item.variant;
        }
    }

    /// A path used as a value (not as a callee).
    Type inferPath(PathExpr p, Type expected)
    {
        resolvePath(p);
        final switch (p.res)
        {
        case ResK.local:
            if (expected !is null)
            {
                if (!unify(expected, p.var.type))
                    throw mismatch(p.pos);
            }
            return p.var.type;
        case ResK.variant:
        {
            auto v = p.variant;
            if (v.payload.length != 0)
                throw err(Kind.badValueRef, p.namePos);
            return variantCall(p.pos, v, null, expected);
        }
        case ResK.fn, ResK.methodPath, ResK.none:
            throw err(Kind.badValueRef, p.namePos);
        }
    }

    /// The generic-call rule of 9.4 for an enum variant constructor.
    Type variantCall(Pos pos, VariantInfo v, Expr[] args, Type expected)
    {
        Type[] tps;
        foreach (p; v.decl.tparams)
            tps ~= p.type;
        return genericCall(pos, v.decl.tparams, v.payload, mkNamed(v.decl, tps), args, expected);
    }

    // ------------------------------------------------------------ calls

    /// Section 9.4.
    Type genericCall(Pos pos, const(TypeParam)[] tps, Type[] params, Type ret, Expr[] args, Type expected)
    {
        if (args.length != params.length)
            throw err(Kind.arity, pos);
        beginOwner();
        Type[] vars;
        foreach (_; tps)
            vars ~= freshVar();
        foreach (i, a; args)
            check(a, subst(params[i], tps, vars));
        if (expected !is null)
        {
            if (!unify(subst(ret, tps, vars), expected))
                throw mismatch(pos);
        }
        auto owned = endOwner();
        foreach (v; owned)
            if (hasUnsolved(v))
                throw err(Kind.cannotInfer, pos);
        foreach (i, p; tps)
            if (!holdsAllBounds(vars[i], p))
                throw err(Kind.unsatisfiedBound, pos);
        return zonk(subst(ret, tps, vars));
    }

    Type inferCall(CallExpr e, Type expected)
    {
        if (e.args.length > 16)
            throw err(Kind.badArity, e.pos);
        auto callee = e.callee;
        if (callee.kind == EK.path)
        {
            auto p = cast(PathExpr) callee;
            resolvePath(p);
            switch (p.res)
            {
            case ResK.fn:
            {
                auto f = p.fn;
                e.fn = f;
                e.ck = f.builtinId >= 0 ? CallK.builtin : CallK.direct;
                return genericCall(e.pos, f.tparams, f.params, f.ret, e.args, expected);
            }
            case ResK.variant:
                e.ck = CallK.variant;
                e.variant = p.variant;
                return variantCall(e.pos, p.variant, e.args, expected);
            case ResK.methodPath:
            {
                e.ck = CallK.trait;
                e.trait = p.trait;
                e.methodIdx = p.methodIdx;
                auto r = traitPathCall(e, p);
                return finishDefault(e, r, expected);
            }
            default:
                break;
            }
        }
        // indirect call of a function value
        e.ck = CallK.indirect;
        auto ft = prune(infer(callee));
        if (ft.kind != TK.fn)
            throw err(Kind.notCallable, callee.pos);
        if (ft.args.length != e.args.length)
            throw err(Kind.arity, callee.pos);
        foreach (i, a; e.args)
            check(a, ft.args[i]);
        return finishDefault(e, ft.ret, expected);
    }

    /// The default checking rule applied to a call without a dedicated one.
    Type finishDefault(Expr e, Type actual, Type expected)
    {
        if (expected !is null && !unify(expected, actual))
            throw mismatch(e.pos);
        return actual;
    }

    Type traitPathCall(CallExpr e, PathExpr p)
    {
        if (e.args.length == 0)
            throw err(Kind.arity, p.namePos);
        auto r = infer(e.args[0]);
        return callTraitMethod(p.namePos, e.trait, e.methodIdx, r, e.args[1 .. $]);
    }

    Type inferMethod(MethodExpr e)
    {
        if (e.args.length > 16)
            throw err(Kind.badArity, e.namePos);
        auto r = infer(e.recv);
        auto cands = w.traitsWithMethod(mod, e.name);
        if (cands.length == 0)
            throw err(Kind.noMethod, e.namePos);
        if (cands.length > 1)
            throw err(Kind.ambigMethod, e.namePos);
        auto tr = cands[0];
        e.trait = tr;
        e.methodIdx = tr.methodIndex(e.name);
        return callTraitMethod(e.namePos, tr, e.methodIdx, r, e.args);
    }

    /// Steps 3 to 6 of 8.5. `r` is the receiver's type; `args` exclude the receiver.
    Type callTraitMethod(Pos namePos, TraitInfo tr, int mi, Type r, Expr[] args)
    {
        auto sig = tr.methods[mi];
        if (args.length != sig.params.length)
            throw err(Kind.arity, namePos);
        auto rt = prune(r);
        if (rt.kind == TK.param)
        {
            if (!rt.param.hasBound(tr))
                throw err(Kind.unsatisfiedBound, namePos);
        }
        else if (!holdsUser(rt, tr))
            throw err(Kind.unsatisfiedBound, namePos);
        auto selfs = [tr.selfParam];
        foreach (i, a; args)
            check(a, subst(sig.params[i], selfs, [rt]));
        return subst(sig.ret, selfs, [rt]);
    }

    // ------------------------------------------------------------ struct literals

    Type inferStructLit(StructLitExpr e, Type expected)
    {
        auto d = lookupDecl(e.qual, e.qualPos, e.name, e.namePos, e.pos);
        if (d is null || d.isEnum)
            throw err(Kind.notStruct, e.pos);
        e.decl = d;
        beginOwner();
        Type[] vars;
        foreach (_; d.tparams)
            vars ~= freshVar();
        auto st = mkNamed(d, vars);
        if (expected !is null && !unify(st, expected))
            throw mismatch(e.pos);
        e.fieldOf = new int[e.inits.length];
        foreach (i, ref f; e.inits)
        {
            foreach (j; 0 .. i)
                if (e.inits[j].name == f.name)
                    throw err(Kind.dupField, f.pos);
            const idx = d.fieldIndex(f.name);
            if (idx < 0)
                throw err(Kind.unknownField, f.pos);
            e.fieldOf[i] = idx;
        }
        foreach (fi, fl; d.fields)
        {
            int at = -1;
            foreach (i; 0 .. e.inits.length)
                if (e.fieldOf[i] == cast(int) fi)
                    at = cast(int) i;
            if (at < 0)
                throw err(Kind.missingField, e.pos);
            check(e.inits[at].value, subst(fl.type, d.tparams, vars));
        }
        auto owned = endOwner();
        foreach (v; owned)
            if (hasUnsolved(v))
                throw err(Kind.cannotInfer, e.pos);
        return zonk(st);
    }
}

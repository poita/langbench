/// Items, namespaces and type resolution (passes 3.1 to 3.6 of the language specification).
module langvm.resolve;

import langvm.ast;
import langvm.diag;
import langvm.lexer;
import langvm.model;
import langvm.parser;
import langvm.signatures;
import langvm.world;
import std.algorithm : sort;
import std.utf : toUTF32;

/// The scope in which written types are resolved.
struct TyScope
{
    ModuleDecl mod;
    TypeParam[] tparams;
    /// The meaning of `Self` (null outside traits and impls).
    Type selfType;
}

private bool isReserved(string n)
{
    switch (n)
    {
    case "Int", "Float", "Bool", "Char", "Str", "Unit", "Self":
        return true;
    default:
        return false;
    }
}

private Type primitiveByName(string n)
{
    switch (n)
    {
    case "Int":
        return tInt;
    case "Float":
        return tFloat;
    case "Bool":
        return tBool;
    case "Char":
        return tChar;
    case "Str":
        return tStr;
    case "Unit":
        return tUnit;
    default:
        return null;
    }
}

/// Resolves a trait reference appearing in `mod` (a bound or the trait of an impl).
TraitDecl resolveTraitRef(World w, ModuleDecl mod, TraitRefAst r)
{
    if (r.qual.length)
    {
        auto pm = r.qual in mod.imports;
        if (pm is null)
            fail("unknown-module", r.qualPos);
        auto m = *pm;
        auto pt = r.name in m.traits;
        if (pt is null)
            fail("unknown-trait", r.namePos);
        if (!pt.pub && m !is mod)
            fail("not-public", r.namePos);
        return *pt;
    }
    if (auto pt = r.name in mod.traits)
        return *pt;
    switch (r.name)
    {
    case "Eq":
        return w.trEq;
    case "Ord":
        return w.trOrd;
    case "Key":
        return w.trKey;
    default:
        fail("unknown-trait", r.namePos);
    }
}

/// Finds the type declaration named by an unqualified or qualified path in the types namespace.
/// Returns null when an unqualified name is not a declared type (caller decides what that means).
DataDecl lookupTypeDecl(World w, ModuleDecl mod, string qual, Pos qualPos, string name, Pos namePos)
{
    if (qual.length)
    {
        auto pm = qual in mod.imports;
        if (pm is null)
            fail("unknown-module", qualPos);
        auto m = *pm;
        auto pt = name in m.types;
        if (pt is null)
            fail("unknown-type", namePos);
        if (!pt.pub && m !is mod)
            fail("not-public", namePos);
        return *pt;
    }
    if (auto pt = name in mod.types)
        return *pt;
    if (auto pt = name in w.prelude.types)
        return *pt;
    return null;
}

/// Resolves a written type.
Type resolveType(World w, TyScope sc, TypeExpr te)
{
    final switch (te.kind)
    {
    case TypeExpr.Kind.list:
        return listOf(resolveType(w, sc, te.args[0]));
    case TypeExpr.Kind.map:
        {
            auto k = resolveType(w, sc, te.args[0]);
            auto v = resolveType(w, sc, te.args[1]);
            if (!holdsKey(w, k))
                fail("bad-key-type", te.pos);
            return mapOf(k, v);
        }
    case TypeExpr.Kind.tuple:
        {
            if (te.args.length > 8)
                fail("bad-arity", te.pos);
            Type[] parts;
            foreach (a; te.args)
                parts ~= resolveType(w, sc, a);
            return new Type(TK.tuple, parts);
        }
    case TypeExpr.Kind.fn:
        {
            if (te.args.length > 16)
                fail("bad-arity", te.pos);
            Type[] parts;
            foreach (a; te.args)
                parts ~= resolveType(w, sc, a);
            parts ~= te.ret is null ? tUnit : resolveType(w, sc, te.ret);
            return new Type(TK.fn, parts);
        }
    case TypeExpr.Kind.path:
        return resolvePathType(w, sc, te);
    }
}

private Type resolvePathType(World w, TyScope sc, TypeExpr te)
{
    if (te.qual.length)
    {
        auto d = lookupTypeDecl(w, sc.mod, te.qual, te.qualPos, te.name, te.namePos);
        return instantiateNamed(w, sc, te, d);
    }
    foreach (tp; sc.tparams)
    {
        if (tp.name == te.name)
        {
            if (te.hasArgs)
                fail("arity-type", te.pos);
            return paramOf(tp);
        }
    }
    if (te.name == "Self")
    {
        if (sc.selfType is null)
            fail("self-outside", te.pos);
        if (te.hasArgs)
            fail("arity-type", te.pos);
        return sc.selfType;
    }
    if (auto pr = primitiveByName(te.name))
    {
        if (te.hasArgs)
            fail("arity-type", te.pos);
        return pr;
    }
    auto d = lookupTypeDecl(w, sc.mod, null, Pos.init, te.name, te.namePos);
    if (d is null)
        fail("unknown-type", te.namePos);
    return instantiateNamed(w, sc, te, d);
}

private Type instantiateNamed(World w, TyScope sc, TypeExpr te, DataDecl d)
{
    if (te.args.length != d.tparams.length)
        fail("arity-type", te.pos);
    Type[] args;
    foreach (a; te.args)
        args ~= resolveType(w, sc, a);
    return namedOf(d, args);
}

// ------------------------------------------------------------------ world construction

private TypeParam[] makeTParams(GenParamAst[] gen)
{
    TypeParam[] r;
    foreach (g; gen)
        r ~= new TypeParam(g.name, g.pos);
    return r;
}

private void resolveBounds(World w, ModuleDecl mod, TypeParam[] tps, GenParamAst[] gen)
{
    foreach (i, g; gen)
        foreach (b; g.bounds)
            tps[i].bounds ~= resolveTraitRef(w, mod, b);
}

private DataDecl newData(World w, ModuleDecl mod, string name, bool isEnum, bool pub, Pos pos, GenParamAst[] gen)
{
    auto d = new DataDecl;
    d.name = name;
    d.mod = mod;
    d.isEnum = isEnum;
    d.pub = pub;
    d.id = cast(int) w.datas.length;
    d.pos = pos;
    d.tparams = makeTParams(gen);
    w.datas ~= d;
    return d;
}

private TraitDecl newBuiltinTrait(World w, string name, BuiltinTrait b)
{
    auto t = new TraitDecl;
    t.name = name;
    t.mod = w.prelude;
    t.pub = true;
    t.builtin = b;
    t.id = cast(int) w.traits.length;
    w.traits ~= t;
    return t;
}

private void setupPrelude(World w)
{
    auto p = new ModuleDecl;
    p.name = "<prelude>";
    p.isPrelude = true;
    w.prelude = p;
    w.trEq = newBuiltinTrait(w, "Eq", BuiltinTrait.eq);
    w.trOrd = newBuiltinTrait(w, "Ord", BuiltinTrait.ord);
    w.trKey = newBuiltinTrait(w, "Key", BuiltinTrait.key);

    // Option<T> { Some(T), None } and Result<T, E> { Ok(T), Err(E) }
    auto opt = new DataDecl;
    opt.name = "Option";
    opt.mod = p;
    opt.isEnum = true;
    opt.pub = true;
    opt.id = cast(int) w.datas.length;
    opt.tparams = [new TypeParam("T")];
    w.datas ~= opt;
    auto some = new VariantDecl;
    some.name = "Some";
    some.payload = [paramOf(opt.tparams[0])];
    auto none = new VariantDecl;
    none.name = "None";
    opt.variants = [some, none];
    auto res = new DataDecl;
    res.name = "Result";
    res.mod = p;
    res.isEnum = true;
    res.pub = true;
    res.id = cast(int) w.datas.length;
    res.tparams = [new TypeParam("T"), new TypeParam("E")];
    w.datas ~= res;
    auto ok = new VariantDecl;
    ok.name = "Ok";
    ok.payload = [paramOf(res.tparams[0])];
    auto err = new VariantDecl;
    err.name = "Err";
    err.payload = [paramOf(res.tparams[1])];
    res.variants = [ok, err];
    w.optionDecl = opt;
    w.resultDecl = res;
    p.types["Option"] = opt;
    p.types["Result"] = res;
    foreach (d; [opt, res])
    {
        foreach (i, v; d.variants)
        {
            auto vi = new ValueItem;
            vi.kind = ValueItem.Kind.variant;
            vi.pub = true;
            vi.enumDecl = d;
            vi.variantIdx = cast(int) i;
            p.values[v.name] = vi;
        }
    }

    foreach (idx, sigText; builtinSignatures)
    {
        auto toks = Lexer.lex([toUTF32(sigText)]);
        auto f = Parser.parseSignature(toks);
        auto b = new Builtin;
        b.name = f.name;
        b.index = cast(int) idx;
        b.sig = sigText;
        b.tparams = makeTParams(f.gen);
        resolveBounds(w, p, b.tparams, f.gen);
        auto sc = TyScope(p, b.tparams, null);
        foreach (pa; f.params)
            b.paramTypes ~= resolveType(w, sc, pa.te);
        b.ret = f.ret is null ? tUnit : resolveType(w, sc, f.ret);
        w.builtins ~= b;
        auto vi = new ValueItem;
        vi.kind = ValueItem.Kind.builtin;
        vi.pub = true;
        vi.builtin = b;
        p.values[b.name] = vi;
    }
}

private void enter(T)(ref T[string] ns, string name, T v, Pos pos)
{
    if (name in ns)
        fail("dup-name", pos);
    ns[name] = v;
}

private void pass31(World w)
{
    foreach (mi; w.modules)
    {
        foreach (it; mi.ast.items)
        {
            if (auto s = cast(StructItem) it)
            {
                if (isReserved(s.name))
                    fail("reserved-name", s.namePos);
                auto d = newData(w, mi, s.name, false, s.pub, s.pos, s.gen);
                foreach (f; s.fields)
                    d.fields ~= FieldDecl(f.name, f.pos, f.te, null);
                s.decl = d;
                enter(mi.types, s.name, d, s.namePos);
            }
            else if (auto e = cast(EnumItem) it)
            {
                if (isReserved(e.name))
                    fail("reserved-name", e.namePos);
                auto d = newData(w, mi, e.name, true, e.pub, e.pos, e.gen);
                foreach (v; e.variants)
                {
                    auto vd = new VariantDecl;
                    vd.name = v.name;
                    vd.pos = v.pos;
                    vd.tes = v.payload;
                    d.variants ~= vd;
                }
                e.decl = d;
                enter(mi.types, e.name, d, e.namePos);
                foreach (i, v; d.variants)
                {
                    auto vi = new ValueItem;
                    vi.kind = ValueItem.Kind.variant;
                    vi.pub = e.pub;
                    vi.pos = v.pos;
                    vi.enumDecl = d;
                    vi.variantIdx = cast(int) i;
                    enter(mi.values, v.name, vi, v.pos);
                }
            }
            else if (auto f = cast(FnItem) it)
            {
                auto d = new FuncDecl;
                d.name = f.name;
                d.mod = mi;
                d.pub = f.pub;
                d.kind = FuncKind.free;
                d.pos = f.pos;
                d.namePos = f.namePos;
                d.body = f.body;
                f.decl = d;
                w.funcs ~= d;
                auto vi = new ValueItem;
                vi.kind = ValueItem.Kind.func;
                vi.pub = f.pub;
                vi.pos = f.namePos;
                vi.fn = d;
                enter(mi.values, f.name, vi, f.namePos);
            }
            else if (auto t = cast(TraitItem) it)
            {
                if (isReserved(t.name))
                    fail("reserved-name", t.namePos);
                auto d = new TraitDecl;
                d.name = t.name;
                d.mod = mi;
                d.pub = t.pub;
                d.id = cast(int) w.traits.length;
                d.pos = t.pos;
                d.selfParam = new TypeParam("Self");
                d.selfParam.bounds = [d];
                foreach (m; t.methods)
                {
                    auto md = new MethodDecl;
                    md.name = m.name;
                    md.pos = m.namePos;
                    md.fnPos = m.pos;
                    md.ast = m;
                    md.hasDefault = m.body !is null;
                    if (md.hasDefault)
                    {
                        auto fd = new FuncDecl;
                        fd.name = m.name;
                        fd.mod = mi;
                        fd.kind = FuncKind.traitDefault;
                        fd.pos = m.pos;
                        fd.namePos = m.namePos;
                        fd.body = m.body;
                        fd.trait = d;
                        fd.selfType = paramOf(d.selfParam);
                        md.defaultFn = fd;
                        w.funcs ~= fd;
                    }
                    d.methods ~= md;
                }
                t.decl = d;
                w.traits ~= d;
                enter(mi.traits, t.name, d, t.namePos);
            }
        }
    }
}

private void pass32(World w)
{
    foreach (mi; w.modules)
    {
        foreach (it; mi.ast.items)
        {
            auto u = cast(UseItem) it;
            if (u is null)
                continue;
            auto pm = u.mod in w.byName;
            if (pm is null)
                fail("unknown-module", u.modPos);
            string bound = u.hasAlias ? u.alias_ : u.mod;
            Pos bp = u.hasAlias ? u.aliasPos : u.modPos;
            enter(mi.imports, bound, *pm, bp);
        }
        mi.importOrder = mi.imports.keys;
        sort(mi.importOrder);
    }
}

private void dupCheckGen(GenParamAst[] gen)
{
    bool[string] seen;
    foreach (g; gen)
    {
        if (g.name in seen)
            fail("dup-name", g.pos);
        seen[g.name] = true;
    }
}

private void dupCheckParams(ParamAst[] ps)
{
    bool[string] seen;
    foreach (p; ps)
    {
        if (p.name in seen)
            fail("dup-name", p.pos);
        seen[p.name] = true;
    }
}

private void dupCheckMethods(MethodAst[] ms)
{
    bool[string] seen;
    foreach (m; ms)
    {
        if (m.name in seen)
            fail("dup-name", m.namePos);
        seen[m.name] = true;
    }
    foreach (m; ms)
        dupCheckParams(m.params);
}

private void pass33(World w)
{
    foreach (mi; w.modules)
    {
        foreach (it; mi.ast.items)
        {
            if (auto f = cast(FnItem) it)
            {
                dupCheckGen(f.gen);
                dupCheckParams(f.params);
            }
            else if (auto s = cast(StructItem) it)
            {
                dupCheckGen(s.gen);
                dupCheckParams(s.fields);
            }
            else if (auto e = cast(EnumItem) it)
            {
                dupCheckGen(e.gen);
                bool[string] seen;
                foreach (v; e.variants)
                {
                    if (v.name in seen)
                        fail("dup-name", v.pos);
                    seen[v.name] = true;
                }
            }
            else if (auto t = cast(TraitItem) it)
                dupCheckMethods(t.methods);
            else if (auto im = cast(ImplAst) it)
            {
                dupCheckGen(im.gen);
                dupCheckMethods(im.methods);
            }
        }
    }
}

private void fillFuncSignature(World w, FuncDecl fd, MethodAst m, TyScope sc)
{
    foreach (p; m.params)
    {
        fd.paramNames ~= p.name;
        fd.paramPos ~= p.pos;
        fd.paramTypes ~= resolveType(w, sc, p.te);
    }
    fd.ret = m.ret is null ? tUnit : resolveType(w, sc, m.ret);
    fd.signatureResolved = true;
}

private void pass34(World w)
{
    foreach (mi; w.modules)
    {
        foreach (it; mi.ast.items)
        {
            if (auto f = cast(FnItem) it)
            {
                auto d = f.decl;
                d.tparams = makeTParams(f.gen);
                resolveBounds(w, mi, d.tparams, f.gen);
                auto sc = TyScope(mi, d.tparams, null);
                foreach (p; f.params)
                {
                    d.paramNames ~= p.name;
                    d.paramPos ~= p.pos;
                    d.paramTypes ~= resolveType(w, sc, p.te);
                }
                d.ret = f.ret is null ? tUnit : resolveType(w, sc, f.ret);
                d.signatureResolved = true;
            }
            else if (auto s = cast(StructItem) it)
            {
                auto d = s.decl;
                auto sc = TyScope(mi, d.tparams, null);
                foreach (ref fl; d.fields)
                    fl.ty = resolveType(w, sc, fl.te);
            }
            else if (auto e = cast(EnumItem) it)
            {
                auto d = e.decl;
                auto sc = TyScope(mi, d.tparams, null);
                foreach (v; d.variants)
                    foreach (te; v.tes)
                        v.payload ~= resolveType(w, sc, te);
            }
            else if (auto t = cast(TraitItem) it)
            {
                auto d = t.decl;
                auto sc = TyScope(mi, null, paramOf(d.selfParam));
                foreach (md; d.methods)
                {
                    foreach (p; md.ast.params)
                        md.paramTypes ~= resolveType(w, sc, p.te);
                    md.ret = md.ast.ret is null ? tUnit : resolveType(w, sc, md.ast.ret);
                    if (md.hasDefault)
                    {
                        auto fd = md.defaultFn;
                        foreach (p; md.ast.params)
                        {
                            fd.paramNames ~= p.name;
                            fd.paramPos ~= p.pos;
                        }
                        fd.paramTypes = md.paramTypes;
                        fd.ret = md.ret;
                        fd.signatureResolved = true;
                    }
                }
            }
            else if (auto im = cast(ImplAst) it)
            {
                auto d = new ImplDecl;
                im.decl = d;
                d.mod = mi;
                d.ast = im;
                d.pos = im.pos;
                d.tparams = makeTParams(im.gen);
                resolveBounds(w, mi, d.tparams, im.gen);
                d.trait = resolveTraitRef(w, mi, im.trait);
                auto dummySelf = paramOf(new TypeParam("Self"));
                d.head = resolveType(w, TyScope(mi, d.tparams, dummySelf), im.head);
                d.headCtor = headCtorOf(d.head);
                auto sc = TyScope(mi, d.tparams, d.head);
                foreach (m; im.methods)
                {
                    auto fd = new FuncDecl;
                    fd.name = m.name;
                    fd.mod = mi;
                    fd.kind = FuncKind.implMethod;
                    fd.pos = m.pos;
                    fd.namePos = m.namePos;
                    fd.body = m.body;
                    fd.tparams = d.tparams;
                    fd.selfType = d.head;
                    fd.trait = d.trait;
                    fd.impl = d;
                    fillFuncSignature(w, fd, m, sc);
                    d.methods ~= fd;
                    w.funcs ~= fd;
                }
            }
        }
    }
}

private bool headOk(ImplDecl d)
{
    auto h = prune(d.head);
    bool isOwn(Type t)
    {
        t = prune(t);
        if (t.k != TK.param)
            return false;
        foreach (p; d.tparams)
            if (p is t.tp)
                return true;
        return false;
    }

    switch (h.k)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str, TK.unit:
        return true;
    case TK.list:
        return isOwn(h.args[0]);
    case TK.map:
        return isOwn(h.args[0]) && isOwn(h.args[1]) && prune(h.args[0]).tp !is prune(h.args[1]).tp;
    case TK.named:
        foreach (i, a; h.args)
        {
            if (!isOwn(a))
                return false;
            foreach (b; h.args[0 .. i])
                if (prune(a).tp is prune(b).tp)
                    return false;
        }
        return true;
    default:
        return false;
    }
}

private bool mentions(Type t, TypeParam p)
{
    t = prune(t);
    if (t.k == TK.param)
        return t.tp is p;
    foreach (a; t.args)
        if (mentions(a, p))
            return true;
    return false;
}

private void pass35(World w)
{
    foreach (mi; w.modules)
    {
        foreach (it; mi.ast.items)
        {
            auto im = cast(ImplAst) it;
            if (im is null)
                continue;
            auto d = im.decl;
            if (d.trait.builtin != BuiltinTrait.none)
                fail("builtin-trait-impl", im.pos);
            if (!headOk(d))
                fail("bad-impl-head", im.head.pos);
            foreach (p; d.tparams)
                if (!mentions(d.head, p))
                    fail("unused-param", p.pos);
            if (w.findImpl(d.trait, d.headCtor) !is null)
                fail("dup-impl", im.pos);
            w.registerImpl(d);
            auto tr = d.trait;
            foreach (md; tr.methods)
            {
                if (md.hasDefault)
                    continue;
                bool found = false;
                foreach (f; d.methods)
                    if (f.name == md.name)
                        found = true;
                if (!found)
                    fail("missing-method", im.pos);
            }
            d.byIndex = new FuncDecl[tr.methods.length];
            foreach (f; d.methods)
            {
                int idx = tr.methodIndex(f.name);
                if (idx < 0)
                    fail("extra-method", f.namePos);
                auto md = tr.methods[idx];
                bool ok = md.paramTypes.length == f.paramTypes.length;
                if (ok)
                {
                    auto from = [tr.selfParam];
                    auto to = [d.head];
                    foreach (i, pt; md.paramTypes)
                        if (!typeEq(subst(pt, from, to), f.paramTypes[i]))
                            ok = false;
                    if (!typeEq(subst(md.ret, from, to), f.ret))
                        ok = false;
                }
                if (!ok)
                    fail("sig-mismatch", f.namePos);
                d.byIndex[idx] = f;
            }
        }
    }
}

private void pass36(World w)
{
    auto pm = "main" in w.byName;
    if (pm is null)
        fail("no-main", Pos(1, 1));
    auto pv = "main" in pm.values;
    if (pv is null || pv.kind != ValueItem.Kind.func)
        fail("no-main", Pos(1, 1));
    auto f = pv.fn;
    if (f.tparams.length != 0 || f.paramTypes.length != 0 || prune(f.ret).k != TK.unit)
        fail("no-main", Pos(1, 1));
    w.mainFn = f;
}

/// Builds the world from the parsed modules (in stream order), running passes 3.1 to 3.6.
/// Throws: [CompileError].
World buildWorld(ModuleAst[] asts)
{
    auto w = new World;
    setupPrelude(w);
    foreach (i, a; asts)
    {
        auto mi = new ModuleDecl;
        mi.name = a.name;
        mi.index = cast(int) i;
        mi.ast = a;
        w.modules ~= mi;
        w.byName[a.name] = mi;
    }
    pass31(w);
    pass32(w);
    pass33(w);
    pass34(w);
    pass35(w);
    pass36(w);
    return w;
}

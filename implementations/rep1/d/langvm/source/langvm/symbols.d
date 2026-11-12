/// Items, namespaces, imports and type resolution: pass 3 of SPEC.md section 13.2.
module langvm.symbols;

import std.algorithm : sort;

import langvm.ast;
import langvm.bounds;
import langvm.builtins : builtinIdByName;
import langvm.diag;
import langvm.lexer;
import langvm.parser;
import langvm.prelude;
import langvm.source;
import langvm.types;

/// What a name in the values namespace refers to.
final class ValueItem
{
    FnInfo fn;
    VariantInfo variant;
}

/// A module with its four namespaces.
final class ModInfo
{
    string name;
    int index;
    Item[] items;
    TypeDecl[string] types;
    TraitInfo[string] traits;
    ValueItem[string] values;
    /// Bound import name -> module index.
    int[string] imports;
    /// The module's own traits in declaration order.
    TraitInfo[] traitList;

    private TraitInfo[] visibleCache;
    private bool visibleBuilt;
    private TraitInfo[][string] methodCache;
    private bool methodsBuilt;
}

/// The whole program as seen by the checker and compiler.
final class World
{
    /// User modules in stream order.
    ModInfo[] mods;
    ModInfo prelude;
    TypeDecl[] decls;
    TraitInfo[] traits;
    ImplInfo[] impls;
    TraitInfo eqTrait, ordTrait, keyTrait;
    TypeDecl optionDecl, resultDecl;
    FnInfo mainFn;

    ModInfo moduleOf(int index)
    {
        return index < 0 ? prelude : mods[index];
    }

    /// Traits visible in `m` for method lookup: its own, then the `pub` traits
    /// of the modules it imports (in increasing order of bound name).
    TraitInfo[] visibleTraits(ModInfo m)
    {
        if (m.visibleBuilt)
            return m.visibleCache;
        TraitInfo[] r = m.traitList.dup;
        string[] names = m.imports.keys;
        sort(names);
        foreach (n; names)
        {
            const mi = m.imports[n];
            if (mi == m.index)
                continue;
            foreach (t; mods[mi].traitList)
                if (t.pub)
                {
                    bool seen = false;
                    foreach (x; r)
                        seen |= x is t;
                    if (!seen)
                        r ~= t;
                }
        }
        m.visibleCache = r;
        m.visibleBuilt = true;
        return r;
    }

    /// The visible traits that declare a method called `name`.
    TraitInfo[] traitsWithMethod(ModInfo m, string name)
    {
        if (!m.methodsBuilt)
        {
            foreach (t; visibleTraits(m))
                foreach (me; t.methods)
                    m.methodCache[me.name] ~= t;
            m.methodsBuilt = true;
        }
        if (auto p = name in m.methodCache)
            return *p;
        return null;
    }

    /// Find a trait by name for the `Trait::method` path form (SPEC.md 5.4, rule 2).
    TraitInfo traitByName(ModInfo m, string name)
    {
        foreach (t; visibleTraits(m))
            if (t.name == name)
                return t;
        foreach (b; [eqTrait, ordTrait, keyTrait])
            if (b.name == name)
                return b;
        return null;
    }

    /// Look an unqualified name up in the values namespace: the module, then the prelude.
    ValueItem lookupValue(ModInfo m, string name)
    {
        if (auto p = name in m.values)
            return *p;
        if (auto p = name in prelude.values)
            return *p;
        return null;
    }

    /// Does `name` denote a type (current module or prelude, including primitives)?
    bool isTypeName(ModInfo m, string name)
    {
        switch (name)
        {
        case "Int", "Float", "Bool", "Char", "Str", "Unit", "Self":
            return true;
        default:
            return (name in m.types) !is null || (name in prelude.types) !is null;
        }
    }
}

/// How a written type is resolved: the module, the type parameters in scope
/// and the meaning of `Self` (null outside traits and impls).
struct TypeEnv
{
    ModInfo mod;
    Type[string] tparams;
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

// ---------------------------------------------------------------- type resolution

/// Resolve a written type (SPEC.md section 6.1).
Type resolveType(World w, TypeExpr te, ref TypeEnv env)
{
    final switch (te.kind)
    {
    case TyK.list:
        return mkList(resolveType(w, te.args[0], env));
    case TyK.map:
    {
        auto k = resolveType(w, te.args[0], env);
        auto v = resolveType(w, te.args[1], env);
        if (!holdsKey(k))
            throw err(Kind.badKeyType, te.pos);
        return mkMap(k, v);
    }
    case TyK.tuple:
    {
        if (te.args.length > 8)
            throw err(Kind.badArity, te.pos);
        Type[] cs;
        foreach (a; te.args)
            cs ~= resolveType(w, a, env);
        return mkTuple(cs);
    }
    case TyK.fn:
    {
        if (te.args.length > 16)
            throw err(Kind.badArity, te.pos);
        Type[] ps;
        foreach (a; te.args)
            ps ~= resolveType(w, a, env);
        Type r = te.ret is null ? tUnit : resolveType(w, te.ret, env);
        return mkFn(ps, r);
    }
    case TyK.path:
        return resolvePathType(w, te, env);
    }
}

private Type resolvePathType(World w, TypeExpr te, ref TypeEnv env)
{
    TypeDecl decl;
    if (te.qual.length == 0)
    {
        const name = te.name;
        if (auto p = name in env.tparams)
        {
            if (te.args.length)
                throw err(Kind.arityType, te.pos);
            return *p;
        }
        if (name == "Self")
        {
            if (env.selfType is null)
                throw err(Kind.selfOutside, te.pos);
            if (te.args.length)
                throw err(Kind.arityType, te.pos);
            return env.selfType;
        }
        Type prim;
        switch (name)
        {
        case "Int": prim = tInt; break;
        case "Float": prim = tFloat; break;
        case "Bool": prim = tBool; break;
        case "Char": prim = tChar; break;
        case "Str": prim = tStr; break;
        case "Unit": prim = tUnit; break;
        default: break;
        }
        if (prim !is null)
        {
            if (te.args.length)
                throw err(Kind.arityType, te.pos);
            return prim;
        }
        if (auto p = name in env.mod.types)
            decl = *p;
        else if (auto p = name in w.prelude.types)
            decl = *p;
        else
            throw err(Kind.unknownType, te.namePos);
    }
    else
    {
        auto mp = te.qual in env.mod.imports;
        if (mp is null)
            throw err(Kind.unknownModule, te.qualPos);
        auto m = w.mods[*mp];
        auto p = te.name in m.types;
        if (p is null)
            throw err(Kind.unknownType, te.namePos);
        decl = *p;
        if (!decl.pub && m !is env.mod)
            throw err(Kind.notPublic, te.namePos);
    }
    if (te.args.length != decl.tparams.length)
        throw err(Kind.arityType, te.pos);
    Type[] args;
    foreach (a; te.args)
        args ~= resolveType(w, a, env);
    return mkNamed(decl, args);
}

/// Resolve a trait reference in module `cur` (SPEC.md section 5.4).
TraitInfo resolveTraitRef(World w, ModInfo cur, in TraitRef r)
{
    if (r.qual.length == 0)
    {
        if (auto p = r.name in cur.traits)
            return *p;
        foreach (b; [w.eqTrait, w.ordTrait, w.keyTrait])
            if (b.name == r.name)
                return b;
        throw err(Kind.unknownTrait, r.namePos);
    }
    auto mp = r.qual in cur.imports;
    if (mp is null)
        throw err(Kind.unknownModule, r.qualPos);
    auto m = w.mods[*mp];
    auto p = r.name in m.traits;
    if (p is null)
        throw err(Kind.unknownTrait, r.namePos);
    if (!p.pub && m !is cur)
        throw err(Kind.notPublic, r.namePos);
    return *p;
}

// ---------------------------------------------------------------- building the world

/// Build the symbol tables from parsed modules: passes 3.1 to 3.6.
/// `parsed[i]` holds the items of `srcs[i]`.
World buildWorld(const SourceModule[] srcs, Item[][] parsed)
{
    auto w = new World();
    foreach (n; ["Eq", "Ord", "Key"])
    {
        auto t = new TraitInfo();
        t.name = n;
        t.builtin = true;
        t.id = -1 - cast(int) w.traits.length;
        w.traits ~= t;
    }
    w.eqTrait = w.traits[0];
    w.ordTrait = w.traits[1];
    w.keyTrait = w.traits[2];
    w.traits = null;

    // The prelude is declared and resolved first; its source is fixed, so it never fails.
    w.prelude = new ModInfo();
    w.prelude.name = "<prelude>";
    w.prelude.index = -1;
    w.prelude.items = parseModule(lex(SourceModule("<prelude>", splitLines(decodeUtf8(preludeSource)))));
    declareItems(w, w.prelude);
    foreach (it; w.prelude.items)
        if (it.kind == IK.fn)
        {
            auto f = cast(FnDecl) it;
            f.info.builtinId = builtinIdByName(f.name);
            assert(f.info.builtinId >= 0, "prelude function without an implementation: " ~ f.name);
        }
    resolveSignatures(w, w.prelude);
    w.optionDecl = w.prelude.types["Option"];
    w.resultDecl = w.prelude.types["Result"];

    foreach (i, s; srcs)
    {
        auto m = new ModInfo();
        m.name = s.name;
        m.index = cast(int) i;
        m.items = parsed[i];
        w.mods ~= m;
    }
    foreach (m; w.mods)
        declareItems(w, m); // 3.1
    foreach (m; w.mods)
        declareImports(w, m); // 3.2
    foreach (m; w.mods)
        checkInternalDuplicates(m); // 3.3
    foreach (m; w.mods)
        resolveSignatures(w, m); // 3.4
    foreach (m; w.mods)
        checkImpls(w, m); // 3.5
    findMain(w); // 3.6
    return w;
}

/// 3.1: declare every item's name in its namespace.
private void declareItems(World w, ModInfo m)
{
    const isPrelude = m.index < 0;
    foreach (it; m.items)
    {
        switch (it.kind)
        {
        case IK.struct_:
        {
            auto s = cast(StructDecl) it;
            auto d = newDecl(w, m, s.name, s.namePos, s.pub, false, s.gparams);
            s.info = d;
            break;
        }
        case IK.enum_:
        {
            auto e = cast(EnumDecl) it;
            auto d = newDecl(w, m, e.name, e.namePos, e.pub, true, e.gparams);
            e.info = d;
            foreach (i, v; e.variants)
            {
                if (v.name in m.values)
                    throw err(Kind.dupName, v.pos);
                auto vi = new VariantInfo();
                vi.name = v.name;
                vi.decl = d;
                vi.index = cast(int) i;
                vi.pos = v.pos;
                d.variants ~= vi;
                auto item = new ValueItem();
                item.variant = vi;
                m.values[v.name] = item;
            }
            break;
        }
        case IK.trait:
        {
            auto t = cast(TraitDecl) it;
            if (isReserved(t.name))
                throw err(Kind.reservedName, t.namePos);
            if (t.name in m.traits)
                throw err(Kind.dupName, t.namePos);
            auto ti = new TraitInfo();
            ti.name = t.name;
            ti.id = cast(int) w.traits.length;
            ti.module_ = m.index;
            ti.pub = t.pub;
            ti.decl = t;
            ti.selfParam = new TypeParam("Self");
            w.traits ~= ti;
            m.traits[t.name] = ti;
            m.traitList ~= ti;
            t.info = ti;
            break;
        }
        case IK.fn:
        {
            auto f = cast(FnDecl) it;
            if (f.name in m.values)
                throw err(Kind.dupName, f.namePos);
            auto fi = new FnInfo();
            fi.name = f.name;
            fi.module_ = m.index;
            fi.pub = f.pub;
            fi.decl = f;
            f.info = fi;
            auto item = new ValueItem();
            item.fn = fi;
            m.values[f.name] = item;
            break;
        }
        default:
            break;
        }
    }
}

private TypeDecl newDecl(World w, ModInfo m, string name, Pos namePos, bool pub, bool isEnum,
    const GenParam[] gps)
{
    if (isReserved(name))
        throw err(Kind.reservedName, namePos);
    if (name in m.types)
        throw err(Kind.dupName, namePos);
    auto d = new TypeDecl();
    d.name = name;
    d.id = cast(int) w.decls.length;
    d.module_ = m.index;
    d.pub = pub;
    d.isEnum = isEnum;
    d.pos = namePos;
    foreach (g; gps)
        d.tparams ~= new TypeParam(g.name);
    w.decls ~= d;
    m.types[name] = d;
    return d;
}

/// 3.2: process `use` declarations.
private void declareImports(World w, ModInfo m)
{
    foreach (it; m.items)
    {
        if (it.kind != IK.use)
            continue;
        auto u = cast(UseItem) it;
        int target = -1;
        foreach (x; w.mods)
            if (x.name == u.mod)
                target = x.index;
        if (target < 0)
            throw err(Kind.unknownModule, u.modPos);
        if (u.alias_ in m.imports)
            throw err(Kind.dupName, u.aliasPos);
        m.imports[u.alias_] = target;
    }
}

private void dupNames(T)(const T[] xs)
{
    foreach (i, a; xs)
        foreach (j; 0 .. i)
            if (xs[j].name == a.name)
                throw err(Kind.dupName, a.pos);
}

/// 3.3: repeated names inside one item.
private void checkInternalDuplicates(ModInfo m)
{
    foreach (it; m.items)
    {
        switch (it.kind)
        {
        case IK.fn:
        {
            auto f = cast(FnDecl) it;
            dupNames(f.gparams);
            dupNames(f.params);
            break;
        }
        case IK.struct_:
        {
            auto s = cast(StructDecl) it;
            dupNames(s.gparams);
            dupNames(s.fields);
            break;
        }
        case IK.enum_:
            dupNames((cast(EnumDecl) it).gparams);
            break;
        case IK.trait:
        {
            auto t = cast(TraitDecl) it;
            dupMethods(t.methods);
            break;
        }
        case IK.impl:
        {
            auto im = cast(ImplDecl) it;
            dupNames(im.gparams);
            dupMethods(im.methods);
            break;
        }
        default:
            break;
        }
    }
}

private void dupMethods(FnDecl[] methods)
{
    foreach (i, a; methods)
        foreach (j; 0 .. i)
            if (methods[j].name == a.name)
                throw err(Kind.dupName, a.namePos);
    foreach (f; methods)
        dupNames(f.params);
}

/// Create the rigid parameters for `gps` (or reuse `existing`), resolve their
/// bounds, and register them in `env`.
private TypeParam[] makeTypeParams(World w, ModInfo m, const GenParam[] gps, ref TypeEnv env,
    TypeParam[] existing = null)
{
    TypeParam[] ps = existing;
    if (ps is null)
        foreach (g; gps)
            ps ~= new TypeParam(g.name);
    foreach (p; ps)
        env.tparams[p.name] = p.type;
    foreach (i, g; gps)
    {
        foreach (b; g.bounds)
        {
            auto tr = resolveTraitRef(w, m, b);
            if (tr is w.eqTrait)
                ps[i].eq = true;
            else if (tr is w.ordTrait)
                ps[i].ord = true;
            else if (tr is w.keyTrait)
                ps[i].key = true;
            else
                ps[i].bounds ~= tr;
        }
    }
    return ps;
}

/// 3.4: resolve every type written in an item's header.
private void resolveSignatures(World w, ModInfo m)
{
    foreach (it; m.items)
    {
        switch (it.kind)
        {
        case IK.fn:
        {
            auto f = cast(FnDecl) it;
            auto fi = f.info;
            TypeEnv env;
            env.mod = m;
            fi.tparams = makeTypeParams(w, m, f.gparams, env);
            foreach (p; f.params)
                fi.params ~= resolveType(w, p.type, env);
            fi.ret = f.ret is null ? tUnit : resolveType(w, f.ret, env);
            fi.tpScope = env.tparams;
            break;
        }
        case IK.struct_:
        {
            auto s = cast(StructDecl) it;
            TypeEnv env;
            env.mod = m;
            makeTypeParams(w, m, s.gparams, env, s.info.tparams);
            foreach (f; s.fields)
                s.info.fields ~= Field(f.name, resolveType(w, f.type, env));
            break;
        }
        case IK.enum_:
        {
            auto e = cast(EnumDecl) it;
            TypeEnv env;
            env.mod = m;
            makeTypeParams(w, m, e.gparams, env, e.info.tparams);
            foreach (i, v; e.variants)
                foreach (pt; v.payload)
                    e.info.variants[i].payload ~= resolveType(w, pt, env);
            break;
        }
        case IK.trait:
        {
            auto t = cast(TraitDecl) it;
            auto ti = t.info;
            TypeEnv env;
            env.mod = m;
            env.selfType = ti.selfParam.type;
            ti.selfParam.bounds = [ti];
            foreach (i, md; t.methods)
            {
                auto sig = new MethodSig();
                sig.name = md.name;
                sig.index = cast(int) i;
                sig.decl = md;
                foreach (p; md.params)
                    sig.params ~= resolveType(w, p.type, env);
                sig.ret = md.ret is null ? tUnit : resolveType(w, md.ret, env);
                ti.methods ~= sig;
                if (md.body !is null)
                {
                    auto fi = new FnInfo();
                    fi.name = md.name;
                    fi.module_ = m.index;
                    fi.decl = md;
                    fi.params = [ti.selfParam.type] ~ sig.params;
                    fi.ret = sig.ret;
                    fi.selfType = ti.selfParam.type;
                    fi.trait = ti;
                    md.info = fi;
                    sig.defaultFn = fi;
                }
            }
            break;
        }
        case IK.impl:
        {
            auto im = cast(ImplDecl) it;
            auto info = new ImplInfo();
            info.decl = im;
            info.module_ = m.index;
            im.info = info;
            TypeEnv env;
            env.mod = m;
            info.tparams = makeTypeParams(w, m, im.gparams, env);
            info.trait = resolveTraitRef(w, m, im.trait);
            env.selfType = (new TypeParam("Self")).type; // placeholder while the head is resolved
            info.head = resolveType(w, im.head, env);
            env.selfType = info.head;
            foreach (md; im.methods)
            {
                auto fi = new FnInfo();
                fi.name = md.name;
                fi.module_ = m.index;
                fi.decl = md;
                fi.params = [info.head];
                foreach (p; md.params)
                    fi.params ~= resolveType(w, p.type, env);
                fi.ret = md.ret is null ? tUnit : resolveType(w, md.ret, env);
                fi.selfType = info.head;
                fi.impl = info;
                fi.tpScope = env.tparams;
                md.info = fi;
            }
            break;
        }
        default:
            break;
        }
    }
}

/// Is `t` a parameter of `ps`?
private bool isOwnParam(Type t, const TypeParam[] ps)
{
    t = prune(t);
    if (t.kind != TK.param)
        return false;
    foreach (p; ps)
        if (p is t.param)
            return true;
    return false;
}

private bool validImplHead(Type h, const TypeParam[] ps)
{
    h = prune(h);
    switch (h.kind)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str, TK.unit:
        return true;
    case TK.list, TK.map, TK.named:
        foreach (i, a; h.args)
        {
            if (!isOwnParam(a, ps))
                return false;
            foreach (j; 0 .. i)
                if (prune(h.args[j]).param is prune(a).param)
                    return false;
        }
        return true;
    default:
        return false;
    }
}

/// 3.5: impl heads, coherence, completeness and signatures.
private void checkImpls(World w, ModInfo m)
{
    foreach (it; m.items)
    {
        if (it.kind != IK.impl)
            continue;
        auto im = cast(ImplDecl) it;
        auto info = im.info;
        auto tr = info.trait;
        if (tr.builtin)
            throw err(Kind.builtinTraitImpl, im.pos);
        if (!validImplHead(info.head, info.tparams))
            throw err(Kind.badImplHead, im.head.pos);
        foreach (i, p; info.tparams)
            if (!mentionsParam(info.head, p))
                throw err(Kind.unusedParam, im.gparams[i].pos);
        info.ctor = headCtor(info.head);
        if (info.ctor in tr.impls)
            throw err(Kind.dupImpl, im.pos);
        tr.impls[info.ctor] = info;
        w.impls ~= info;
        info.methods = new FnInfo[tr.methods.length];
        foreach (md; im.methods)
        {
            const idx = tr.methodIndex(md.name);
            if (idx >= 0)
                info.methods[idx] = md.info;
        }
        foreach (i, sig; tr.methods)
            if (sig.defaultFn is null && info.methods[i] is null)
                throw err(Kind.missingMethod, im.pos);
        foreach (md; im.methods)
        {
            const idx = tr.methodIndex(md.name);
            if (idx < 0)
                throw err(Kind.extraMethod, md.namePos);
            auto sig = tr.methods[idx];
            auto fi = md.info;
            bool ok = fi.params.length == sig.params.length + 1;
            if (ok)
            {
                foreach (j, pt; sig.params)
                    ok = ok && typeEq(fi.params[j + 1], subst(pt, [tr.selfParam], [info.head]));
                ok = ok && typeEq(fi.ret, subst(sig.ret, [tr.selfParam], [info.head]));
            }
            if (!ok)
                throw err(Kind.sigMismatch, md.namePos);
        }
    }
}

/// 3.6: a suitable `main` in module `main`.
private void findMain(World w)
{
    foreach (m; w.mods)
    {
        if (m.name != "main")
            continue;
        if (auto p = "main" in m.values)
            if (p.fn !is null && p.fn.tparams.length == 0 && p.fn.params.length == 0
                && typeEq(p.fn.ret, tUnit))
            {
                w.mainFn = p.fn;
                return;
            }
    }
    throw err(Kind.noMain, Pos(1, 1));
}

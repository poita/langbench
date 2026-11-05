/// The whole-program semantic world: modules, declarations, impl registry, and trait satisfaction.
module langvm.world;

import langvm.ast;
import langvm.diag;
import langvm.model;

/// Everything known about a program after item resolution.
final class World
{
    ModuleDecl[] modules;
    ModuleDecl prelude;
    ModuleDecl[string] byName;
    DataDecl[] datas;
    TraitDecl[] traits;
    FuncDecl[] funcs;
    ImplDecl[] impls;
    Builtin[] builtins;
    TraitDecl trEq, trOrd, trKey;
    DataDecl optionDecl, resultDecl;
    FuncDecl mainFn;
    private ImplDecl[long] implMap;

    /// Registers an impl keyed by (trait, head constructor).
    void registerImpl(ImplDecl im)
    {
        implMap[(cast(long) im.trait.id << 32) | im.headCtor] = im;
        impls ~= im;
    }

    /// The impl of `t` for the head constructor `ctor`, or null.
    ImplDecl findImpl(const TraitDecl t, int ctor)
    {
        auto p = ((cast(long) t.id << 32) | ctor) in implMap;
        return p ? *p : null;
    }

    /// Traits visible in module `m` (declared there, or `pub` in an imported module), no duplicates.
    TraitDecl[] visibleTraits(ModuleDecl m)
    {
        TraitDecl[] r;
        foreach (t; m.traits)
            r ~= t;
        foreach (bound; m.importOrder)
        {
            auto im = m.imports[bound];
            if (im is m)
                continue;
            foreach (t; im.traits)
            {
                if (!t.pub)
                    continue;
                bool dup = false;
                foreach (x; r)
                    if (x is t)
                        dup = true;
                if (!dup)
                    r ~= t;
            }
        }
        return r;
    }
}

/// Head-constructor id of a type, or -1 for types without one (tuples, functions, parameters).
int headCtorOf(Type t)
{
    t = prune(t);
    final switch (t.k)
    {
    case TK.int_:
        return HeadCtor.int_;
    case TK.float_:
        return HeadCtor.float_;
    case TK.bool_:
        return HeadCtor.bool_;
    case TK.char_:
        return HeadCtor.char_;
    case TK.str:
        return HeadCtor.str;
    case TK.unit:
        return HeadCtor.unit;
    case TK.list:
        return HeadCtor.list;
    case TK.map:
        return HeadCtor.map;
    case TK.named:
        return t.decl.headCtor;
    case TK.tuple, TK.fn, TK.param, TK.var:
        return -1;
    }
}

/// True if `Eq` holds for `t` (section 7.1).
bool holdsEq(World w, Type t, ref DataDecl[] assumed)
{
    t = prune(t);
    final switch (t.k)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str, TK.unit:
        return true;
    case TK.list:
        return holdsEq(w, t.args[0], assumed);
    case TK.map:
        return holdsEq(w, t.args[1], assumed);
    case TK.tuple:
        foreach (a; t.args)
            if (!holdsEq(w, a, assumed))
                return false;
        return true;
    case TK.fn:
        return false;
    case TK.param:
        return t.tp.hasBound(w.trEq) || t.tp.hasBound(w.trKey);
    case TK.var:
        return false;
    case TK.named:
        foreach (d; assumed)
            if (d is t.decl)
                return true;
        assumed ~= t.decl;
        scope (exit)
            assumed = assumed[0 .. $ - 1];
        auto d = t.decl;
        if (d.isEnum)
        {
            foreach (v; d.variants)
                foreach (pt; v.payload)
                    if (!holdsEq(w, subst(pt, d.tparams, t.args), assumed))
                        return false;
        }
        else
        {
            foreach (f; d.fields)
                if (!holdsEq(w, subst(f.ty, d.tparams, t.args), assumed))
                    return false;
        }
        return true;
    }
}

/// True if `Ord` holds for `t` (section 7.2).
bool holdsOrd(World w, Type t)
{
    t = prune(t);
    switch (t.k)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str:
        return true;
    case TK.param:
        return t.tp.hasBound(w.trOrd);
    default:
        return false;
    }
}

/// True if `Key` holds for `t` (section 7.3).
bool holdsKey(World w, Type t)
{
    t = prune(t);
    switch (t.k)
    {
    case TK.int_, TK.bool_, TK.char_, TK.str:
        return true;
    case TK.param:
        return t.tp.hasBound(w.trKey);
    default:
        return false;
    }
}

/// True if type `t` satisfies trait `tr` (sections 7 and 8.4).
bool satisfies(World w, Type t, TraitDecl tr)
{
    final switch (tr.builtin)
    {
    case BuiltinTrait.eq:
        {
            DataDecl[] assumed;
            return holdsEq(w, t, assumed);
        }
    case BuiltinTrait.ord:
        return holdsOrd(w, t);
    case BuiltinTrait.key:
        return holdsKey(w, t);
    case BuiltinTrait.none:
        break;
    }
    t = prune(t);
    if (t.k == TK.param)
        return t.tp.hasBound(tr);
    int ctor = headCtorOf(t);
    if (ctor < 0)
        return false;
    auto im = w.findImpl(tr, ctor);
    if (im is null)
        return false;
    // bind the impl's parameters by matching its head against t
    Type[] binding = new Type[im.tparams.length];
    auto head = im.head;
    foreach (i, ha; head.args)
    {
        if (ha.k != TK.param)
            continue;
        foreach (j, p; im.tparams)
            if (p is ha.tp && i < t.args.length)
                binding[j] = t.args[i];
    }
    foreach (j, p; im.tparams)
    {
        foreach (b; p.bounds)
        {
            if (binding[j] is null || !satisfies(w, binding[j], b))
                return false;
        }
    }
    return true;
}

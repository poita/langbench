/// Deciding whether a type satisfies `Eq`, `Ord`, `Key` or a user trait
/// (SPEC.md sections 7 and 8.4).
module langvm.bounds;

import langvm.types;

/// Does `Eq` hold for `t`? Recursive declarations are handled by an assumption
/// set of declarations (SPEC.md section 7.1).
bool holdsEq(Type t)
{
    bool[int] visiting;
    return eqRec(t, visiting);
}

private bool eqRec(Type t, ref bool[int] visiting)
{
    t = prune(t);
    final switch (t.kind)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str, TK.unit:
        return true;
    case TK.list:
        return eqRec(t.args[0], visiting);
    case TK.map:
        return eqRec(t.args[1], visiting);
    case TK.tuple:
        foreach (a; t.args)
            if (!eqRec(a, visiting))
                return false;
        return true;
    case TK.fn:
        return false;
    case TK.param:
        return t.param.eq || t.param.key;
    case TK.var:
        return false;
    case TK.named:
        auto d = t.decl;
        if (d.id in visiting)
            return true;
        visiting[d.id] = true;
        scope (exit)
            visiting.remove(d.id);
        if (d.isEnum)
        {
            foreach (v; d.variants)
                foreach (p; v.payload)
                    if (!eqRec(subst(p, d.tparams, t.args), visiting))
                        return false;
        }
        else
        {
            foreach (f; d.fields)
                if (!eqRec(subst(f.type, d.tparams, t.args), visiting))
                    return false;
        }
        return true;
    }
}

/// Does `Ord` hold for `t`?
bool holdsOrd(Type t)
{
    t = prune(t);
    switch (t.kind)
    {
    case TK.int_, TK.float_, TK.bool_, TK.char_, TK.str:
        return true;
    case TK.param:
        return t.param.ord;
    default:
        return false;
    }
}

/// Does `Key` hold for `t`?
bool holdsKey(Type t)
{
    t = prune(t);
    switch (t.kind)
    {
    case TK.int_, TK.bool_, TK.char_, TK.str:
        return true;
    case TK.param:
        return t.param.key;
    default:
        return false;
    }
}

/// Does the user trait `tr` hold for `t` (SPEC.md section 8.4)?
bool holdsUser(Type t, TraitInfo tr)
{
    t = prune(t);
    if (t.kind == TK.param)
        return t.param.hasBound(tr);
    const c = headCtor(t);
    if (c < 0)
        return false;
    auto pi = c in tr.impls;
    if (pi is null)
        return false;
    auto impl = *pi;
    // Match the impl head against t to bind the impl's parameters.
    Type[] binding = new Type[impl.tparams.length];
    foreach (i, ha; impl.head.args)
    {
        auto h = prune(ha);
        foreach (j, p; impl.tparams)
            if (h.kind == TK.param && h.param is p)
                binding[j] = t.args[i];
    }
    foreach (j, p; impl.tparams)
    {
        if (binding[j] is null)
            continue;
        if (!holdsAllBounds(binding[j], p))
            return false;
    }
    return true;
}

/// Does `t` satisfy every declared bound of the parameter `p`?
bool holdsAllBounds(Type t, const TypeParam p)
{
    if (p.eq && !holdsEq(t))
        return false;
    if (p.ord && !holdsOrd(t))
        return false;
    if (p.key && !holdsKey(t))
        return false;
    foreach (b; p.bounds)
        if (!holdsUser(t, cast(TraitInfo) b))
            return false;
    return true;
}

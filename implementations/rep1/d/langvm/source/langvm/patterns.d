/// Pattern usefulness, exhaustiveness and reachability (section 12.4 of the language specification).
module langvm.patterns;

import langvm.ast;
import langvm.model;

private enum CK : ubyte
{
    variant, boolLit, intLit, charLit, strLit, tuple, strukt, list,
}

private struct Ctor
{
    CK kind;
    long iv;
    dstring sv;
    int idx; // variant index
}

private bool ctorEq(in Ctor a, in Ctor b)
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case CK.variant:
        return a.idx == b.idx;
    case CK.boolLit, CK.intLit, CK.charLit:
        return a.iv == b.iv;
    case CK.strLit:
        return a.sv == b.sv;
    case CK.tuple, CK.strukt:
        return true;
    case CK.list:
        return false; // lists use their own rule
    }
}

/// A deconstructed pattern: a wildcard or a constructor applied to sub-patterns.
private final class DP
{
    bool wild;
    Ctor ctor;
    /// For list patterns: number of element patterns and whether a rest is present.
    bool open;
    DP[] subs;
}

private DP wildDP()
{
    auto d = new DP;
    d.wild = true;
    return d;
}

private DP convert(Pat p, Type t)
{
    t = prune(t);
    if (auto w = cast(WildPat) p)
        return wildDP();
    if (auto ip = cast(IdentPat) p)
    {
        if (ip.enumDecl is null)
            return wildDP();
        auto d = new DP;
        d.ctor = Ctor(CK.variant, 0, null, ip.variantIdx);
        return d;
    }
    if (auto lp = cast(LitPat) p)
    {
        auto d = new DP;
        final switch (lp.kind)
        {
        case LitPat.Kind.int_:
            d.ctor = Ctor(CK.intLit, lp.iv);
            break;
        case LitPat.Kind.char_:
            d.ctor = Ctor(CK.charLit, lp.iv);
            break;
        case LitPat.Kind.bool_:
            d.ctor = Ctor(CK.boolLit, lp.iv);
            break;
        case LitPat.Kind.str:
            d.ctor = Ctor(CK.strLit, 0, lp.sv);
            break;
        case LitPat.Kind.float_:
            return wildDP();
        }
        return d;
    }
    if (auto tp = cast(TuplePat) p)
    {
        auto d = new DP;
        d.ctor.kind = CK.tuple;
        foreach (i, s; tp.subs)
            d.subs ~= convert(s, t.args[i]);
        return d;
    }
    if (auto lp = cast(ListPat) p)
    {
        auto d = new DP;
        d.ctor.kind = CK.list;
        d.open = lp.hasRest;
        foreach (s; lp.subs)
            d.subs ~= convert(s, t.args[0]);
        return d;
    }
    if (auto sp = cast(StructPat) p)
    {
        auto d = new DP;
        d.ctor.kind = CK.strukt;
        auto decl = sp.decl;
        d.subs = new DP[decl.fields.length];
        foreach (ref x; d.subs)
            x = wildDP();
        foreach (fp; sp.fields)
        {
            auto ft = subst(decl.fields[fp.fieldIdx].ty, decl.tparams, t.args);
            d.subs[fp.fieldIdx] = convert(fp.sub, ft);
        }
        return d;
    }
    if (auto vp = cast(VariantPat) p)
    {
        auto d = new DP;
        d.ctor = Ctor(CK.variant, 0, null, vp.variantIdx);
        auto pts = vp.enumDecl.variants[vp.variantIdx].payload;
        foreach (i, s; vp.subs)
            d.subs ~= convert(s, subst(pts[i], vp.enumDecl.tparams, t.args));
        return d;
    }
    assert(0);
}

private int arityOf(in Ctor c, Type t)
{
    t = prune(t);
    final switch (c.kind)
    {
    case CK.variant:
        return cast(int) t.decl.variants[c.idx].payload.length;
    case CK.tuple:
        return cast(int) t.args.length;
    case CK.strukt:
        return cast(int) t.decl.fields.length;
    case CK.boolLit, CK.intLit, CK.charLit, CK.strLit, CK.list:
        return 0;
    }
}

private Type[] subTypes(in Ctor c, Type t)
{
    t = prune(t);
    switch (c.kind)
    {
    case CK.variant:
        {
            Type[] r;
            foreach (pt; t.decl.variants[c.idx].payload)
                r ~= subst(pt, t.decl.tparams, t.args);
            return r;
        }
    case CK.tuple:
        return t.args.dup;
    case CK.strukt:
        {
            Type[] r;
            foreach (f; t.decl.fields)
                r ~= subst(f.ty, t.decl.tparams, t.args);
            return r;
        }
    default:
        return null;
    }
}

private bool specRow(in Ctor c, int arity, DP[] row, out DP[] result)
{
    auto h = row[0];
    if (h.wild)
    {
        DP[] r;
        r.reserve(arity + row.length - 1);
        foreach (_; 0 .. arity)
            r ~= wildDP();
        r ~= row[1 .. $];
        result = r;
        return true;
    }
    if (!ctorEq(h.ctor, c))
        return false;
    result = h.subs ~ row[1 .. $];
    return true;
}

private DP[][] specMatrix(in Ctor c, int arity, DP[][] rows)
{
    DP[][] r;
    foreach (row; rows)
    {
        DP[] s;
        if (specRow(c, arity, row, s))
            r ~= s;
    }
    return r;
}

private bool specListRow(int k, DP[] row, out DP[] result)
{
    auto h = row[0];
    if (h.wild)
    {
        DP[] r;
        foreach (_; 0 .. k)
            r ~= wildDP();
        r ~= row[1 .. $];
        result = r;
        return true;
    }
    int n = cast(int) h.subs.length;
    if (h.open ? n > k : n != k)
        return false;
    DP[] r = h.subs.dup;
    foreach (_; n .. k)
        r ~= wildDP();
    r ~= row[1 .. $];
    result = r;
    return true;
}

/// True if there is a value matched by `q` and by no row of `rows`.
private bool useful(DP[][] rows, DP[] q, Type[] types)
{
    if (q.length == 0)
        return rows.length == 0;
    auto t1 = prune(types[0]);
    auto rest = types[1 .. $];
    if (t1.k == TK.list)
    {
        int lmax = 0;
        foreach (r; rows)
            if (!r[0].wild && cast(int) r[0].subs.length > lmax)
                lmax = cast(int) r[0].subs.length;
        if (!q[0].wild && cast(int) q[0].subs.length > lmax)
            lmax = cast(int) q[0].subs.length;
        foreach (k; 0 .. lmax + 2)
        {
            if (!q[0].wild)
            {
                int n = cast(int) q[0].subs.length;
                if (q[0].open ? k < n : k != n)
                    continue;
            }
            DP[][] sm;
            foreach (r; rows)
            {
                DP[] s;
                if (specListRow(k, r, s))
                    sm ~= s;
            }
            DP[] sq;
            specListRow(k, q, sq);
            Type[] nt;
            foreach (_; 0 .. k)
                nt ~= t1.args[0];
            nt ~= rest;
            if (useful(sm, sq, nt))
                return true;
        }
        return false;
    }
    if (!q[0].wild)
    {
        auto c = q[0].ctor;
        int ar = arityOf(c, t1);
        DP[] sq;
        specRow(c, ar, q, sq);
        return useful(specMatrix(c, ar, rows), sq, subTypes(c, t1) ~ rest);
    }
    // wildcard: compute the used constructor set
    Ctor[] used;
    foreach (r; rows)
    {
        if (r[0].wild)
            continue;
        bool seen = false;
        foreach (u; used)
            if (ctorEq(u, r[0].ctor))
                seen = true;
        if (!seen)
            used ~= r[0].ctor;
    }
    Ctor[] all;
    bool finite = false;
    switch (t1.k)
    {
    case TK.bool_:
        finite = true;
        all = [Ctor(CK.boolLit, 0), Ctor(CK.boolLit, 1)];
        break;
    case TK.tuple:
        finite = true;
        all = [Ctor(CK.tuple)];
        break;
    case TK.named:
        finite = true;
        if (t1.decl.isEnum)
        {
            foreach (i; 0 .. t1.decl.variants.length)
                all ~= Ctor(CK.variant, 0, null, cast(int) i);
        }
        else
            all = [Ctor(CK.strukt)];
        break;
    default:
        break;
    }
    bool covers = finite;
    if (finite)
    {
        foreach (c; all)
        {
            bool found = false;
            foreach (u; used)
                if (ctorEq(u, c))
                    found = true;
            if (!found)
            {
                covers = false;
                break;
            }
        }
    }
    if (covers)
    {
        foreach (c; all)
        {
            int ar = arityOf(c, t1);
            DP[] sq;
            specRow(c, ar, q, sq);
            if (useful(specMatrix(c, ar, rows), sq, subTypes(c, t1) ~ rest))
                return true;
        }
        return false;
    }
    DP[][] def;
    foreach (r; rows)
        if (r[0].wild)
            def ~= r[1 .. $];
    return useful(def, q[1 .. $], rest);
}

/// Result of analysing the arms of a `match`.
struct MatchAnalysis
{
    /// Index of the first unreachable arm, or -1.
    int unreachableArm = -1;
    /// Whether the unguarded arms cover the scrutinee type.
    bool exhaustive;
}

/// Analyses the arms of a match on a scrutinee of type `scrut`.
/// Every arm's pattern must already have been type-checked (and annotated).
MatchAnalysis analyseMatch(Type scrut, MatchArm[] arms)
{
    MatchAnalysis res;
    DP[][] prior;
    foreach (i, arm; arms)
    {
        auto dp = convert(arm.pat, scrut);
        if (res.unreachableArm < 0 && !useful(prior, [dp], [scrut]))
            res.unreachableArm = cast(int) i;
        if (arm.guard is null)
            prior ~= [dp];
    }
    res.exhaustive = !useful(prior, [wildDP()], [scrut]);
    return res;
}

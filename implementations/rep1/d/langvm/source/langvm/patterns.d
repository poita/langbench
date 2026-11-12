/// Match usefulness, exhaustiveness and reachability (SPEC.md section 12.4).
module langvm.patterns;

import langvm.ast;
import langvm.types;

/// The identity of a pattern constructor.
struct CtorKey
{
    /// 0: variant / bool / tuple / struct (`i` is the index); 1: int literal;
    /// 2: char literal; 3: str literal; 4: list (not used as a key).
    int kind;
    long i;
    dstring s;

    bool opEquals(const CtorKey o) const
    {
        return kind == o.kind && i == o.i && s == o.s;
    }
}

/// A pattern reduced to what the usefulness algorithm needs.
final class Cp
{
    bool wild;
    CtorKey ck;
    Cp[] subs;
    /// List patterns: whether a `..` rest was written.
    bool open;
    bool isList;
}

private Cp wildCp()
{
    auto c = new Cp();
    c.wild = true;
    return c;
}

/// Convert a checked pattern.
Cp toCp(Pattern p)
{
    auto c = new Cp();
    final switch (p.kind)
    {
    case PatK.wild, PatK.bind:
        c.wild = true;
        break;
    case PatK.float_:
        c.wild = true; // never reaches here: float patterns are rejected earlier
        break;
    case PatK.int_:
        c.ck = CtorKey(1, p.ival);
        break;
    case PatK.char_:
        c.ck = CtorKey(2, p.ival);
        break;
    case PatK.str:
        c.ck = CtorKey(3, 0, p.sval);
        break;
    case PatK.bool_:
        c.ck = CtorKey(0, p.ival);
        break;
    case PatK.tuple:
        c.ck = CtorKey(0, 0);
        foreach (s; p.subs)
            c.subs ~= toCp(s);
        break;
    case PatK.variant:
        c.ck = CtorKey(0, p.variant.index);
        foreach (s; p.subs)
            c.subs ~= toCp(s);
        break;
    case PatK.struct_:
        c.ck = CtorKey(0, 0);
        c.subs = new Cp[p.decl.fields.length];
        foreach (ref s; c.subs)
            s = wildCp();
        foreach (f; p.fields)
            if (f.pat !is null)
                c.subs[f.fieldIdx] = toCp(f.pat);
        break;
    case PatK.list:
        c.isList = true;
        c.open = p.hasRest;
        foreach (s; p.subs)
            c.subs ~= toCp(s);
        break;
    }
    return c;
}

private Cp[] wilds(size_t n)
{
    auto r = new Cp[n];
    foreach (ref x; r)
        x = wildCp();
    return r;
}

/// The constructors of a finite type: arity and sub-column types of constructor `i`.
private struct Finite
{
    size_t count;
    Type[] delegate(long) sub;
}

private bool finiteInfo(Type t, out Finite f)
{
    t = prune(t);
    switch (t.kind)
    {
    case TK.bool_:
        f = Finite(2, (long _) => cast(Type[]) null);
        return true;
    case TK.unit:
        f = Finite(1, (long _) => cast(Type[]) null);
        return true;
    case TK.tuple:
        f = Finite(1, (long _) => t.args);
        return true;
    case TK.named:
        auto d = t.decl;
        if (d.isEnum)
        {
            f = Finite(d.variants.length, (long i) {
                Type[] r;
                foreach (p; d.variants[cast(size_t) i].payload)
                    r ~= subst(p, d.tparams, t.args);
                return r;
            });
        }
        else
        {
            f = Finite(1, (long _) {
                Type[] r;
                foreach (fl; d.fields)
                    r ~= subst(fl.type, d.tparams, t.args);
                return r;
            });
        }
        return true;
    default:
        return false;
    }
}

private Cp[][] specialize(Cp[][] rows, CtorKey c, size_t arity)
{
    Cp[][] r;
    foreach (row; rows)
    {
        auto p = row[0];
        if (p.wild)
            r ~= wilds(arity) ~ row[1 .. $];
        else if (p.ck == c)
            r ~= p.subs ~ row[1 .. $];
    }
    return r;
}

/// `U(P, q)`: is the row `q` useful against the matrix `rows`?
bool useful(Cp[][] rows, Cp[] q, Type[] tys)
{
    if (q.length == 0)
        return rows.length == 0;
    auto t1 = prune(tys[0]);
    if (t1.kind == TK.list)
        return usefulList(rows, q, tys, t1.args[0]);
    if (!q[0].wild)
    {
        Type[] sub = subColumns(t1, q[0].ck);
        return useful(specialize(rows, q[0].ck, q[0].subs.length), q[0].subs ~ q[1 .. $],
            sub ~ tys[1 .. $]);
    }
    // q[0] is a wildcard
    Finite fin;
    if (finiteInfo(t1, fin))
    {
        CtorKey[] used;
        foreach (row; rows)
            if (!row[0].wild)
            {
                bool seen = false;
                foreach (u; used)
                    seen |= u == row[0].ck;
                if (!seen)
                    used ~= row[0].ck;
            }
        if (used.length == fin.count)
        {
            foreach (c; used)
            {
                auto sub = fin.sub(c.i);
                if (useful(specialize(rows, c, sub.length), wilds(sub.length) ~ q[1 .. $],
                        sub ~ tys[1 .. $]))
                    return true;
            }
            return false;
        }
    }
    Cp[][] def;
    foreach (row; rows)
        if (row[0].wild)
            def ~= row[1 .. $];
    return useful(def, q[1 .. $], tys[1 .. $]);
}

private Type[] subColumns(Type t, CtorKey c)
{
    Finite fin;
    if (finiteInfo(t, fin))
        return fin.sub(c.i);
    return null; // literal constructors have arity 0
}

private bool usefulList(Cp[][] rows, Cp[] q, Type[] tys, Type elem)
{
    size_t lmax = 0;
    foreach (row; rows)
        if (!row[0].wild && row[0].subs.length > lmax)
            lmax = row[0].subs.length;
    if (!q[0].wild && q[0].subs.length > lmax)
        lmax = q[0].subs.length;

    Cp[] expand(Cp p, size_t k, out bool ok)
    {
        ok = true;
        if (p.wild)
            return wilds(k);
        const n = p.subs.length;
        if (p.open)
        {
            if (n > k)
            {
                ok = false;
                return null;
            }
            return p.subs ~ wilds(k - n);
        }
        if (n != k)
        {
            ok = false;
            return null;
        }
        return p.subs;
    }

    foreach (k; 0 .. lmax + 2)
    {
        bool qok;
        auto qk = expand(q[0], k, qok);
        if (!qok)
            continue;
        Cp[][] rk;
        foreach (row; rows)
        {
            bool ok;
            auto e = expand(row[0], k, ok);
            if (ok)
                rk ~= e ~ row[1 .. $];
        }
        Type[] cols = new Type[k];
        foreach (ref c; cols)
            c = elem;
        if (useful(rk, qk ~ q[1 .. $], cols ~ tys[1 .. $]))
            return true;
    }
    return false;
}

/// Index of the first unreachable arm, or -1.
int firstUnreachable(Type scrut, Pattern[] pats, const bool[] guarded)
{
    Cp[][] prior;
    foreach (i, p; pats)
    {
        auto c = toCp(p);
        if (!useful(prior, [c], [scrut]))
            return cast(int) i;
        if (!guarded[i])
            prior ~= [c];
    }
    return -1;
}

/// Do the unguarded arms cover every value of `scrut`?
bool isExhaustive(Type scrut, Pattern[] pats, const bool[] guarded)
{
    Cp[][] rows;
    foreach (i, p; pats)
        if (!guarded[i])
            rows ~= [toCp(p)];
    return !useful(rows, [wildCp()], [scrut]);
}

unittest
{
    // enum Tri { A, B, C(Int) }
    auto tri = new TypeDecl();
    tri.name = "Tri";
    tri.isEnum = true;
    foreach (i, n; ["A", "B", "C"])
    {
        auto v = new VariantInfo();
        v.name = n;
        v.decl = tri;
        v.index = cast(int) i;
        if (i == 2)
            v.payload = [tInt];
        tri.variants ~= v;
    }
    auto ty = mkNamed(tri, []);
    Cp variant(int i, Cp[] subs = null)
    {
        auto c = new Cp();
        c.ck = CtorKey(0, i);
        c.subs = subs;
        return c;
    }
    Cp lit(long v)
    {
        auto c = new Cp();
        c.ck = CtorKey(1, v);
        return c;
    }
    auto w = wildCp();

    // A, B, C(_) covers everything; dropping B does not
    assert(!useful([[variant(0)], [variant(1)], [variant(2, [w])]], [w], [ty]));
    assert(useful([[variant(0)], [variant(2, [w])]], [w], [ty]));
    // C(0) then C(_) is exhaustive together with A and B, and C(_) after C(0) is reachable
    assert(!useful([[variant(0)], [variant(1)], [variant(2, [lit(0)])], [variant(2, [w])]], [w], [ty]));
    assert(useful([[variant(2, [lit(0)])]], [variant(2, [w])], [ty]));
    // a wildcard row makes a later variant unreachable
    assert(!useful([[w]], [variant(0)], [ty]));
}

unittest
{
    // lists: [], [a], [a, b, ..] together cover every length
    auto lt = mkList(tInt);
    Cp list(size_t n, bool open)
    {
        auto c = new Cp();
        c.isList = true;
        c.open = open;
        foreach (_; 0 .. n)
            c.subs ~= wildCp();
        return c;
    }
    auto w = wildCp();
    assert(!useful([[list(0, false)], [list(1, false)], [list(2, true)]], [w], [lt]));
    assert(useful([[list(0, false)], [list(2, true)]], [w], [lt]));
    assert(!useful([[list(1, true)]], [list(2, false)], [lt]));
}

/**
 * Type schemes: generalisation and instantiation, both done in place on the
 * shared type graph with per-node visit stamps (each distinct node is visited
 * at most once per walk).
 */
module typeinfer.scheme;

import typeinfer.types;

/**
 * Quantify, in place, every unbound variable reachable from `t` whose level
 * is greater than `level`.
 *
 * Returns: true if at least one variable was quantified (the type is then a
 * genuine scheme; otherwise it can be used as-is without instantiation).
 */
bool generalize(TypeStore s, TypeId t, int level)
{
    bool any = false;
    generalizeWalk(s, t, level, s.newStamp(), any);
    return any;
}

private void generalizeWalk(TypeStore s, TypeId t, int level, ulong stamp, ref bool any)
{
    t = s.find(t);
    final switch (s.nodes[t].kind)
    {
    case NodeKind.variable:
        if (s.nodes[t].level > level && s.nodes[t].level != genericLevel)
        {
            s.nodes[t].level = genericLevel;
            any = true;
        }
        else if (s.nodes[t].level == genericLevel)
            any = true;
        return;
    case NodeKind.int_, NodeKind.bool_, NodeKind.unit:
        return;
    case NodeKind.arrow:
        if (s.nodes[t].stamp == stamp)
            return;
        s.nodes[t].stamp = stamp;
        generalizeWalk(s, s.nodes[t].a, level, stamp, any);
        generalizeWalk(s, s.nodes[t].b, level, stamp, any);
        return;
    case NodeKind.list:
        if (s.nodes[t].stamp == stamp)
            return;
        s.nodes[t].stamp = stamp;
        generalizeWalk(s, s.nodes[t].a, level, stamp, any);
        return;
    case NodeKind.tuple:
        if (s.nodes[t].stamp == stamp)
            return;
        s.nodes[t].stamp = stamp;
        immutable p = s.nodes[t].a;
        foreach (i; 0 .. s.nodes[t].b)
            generalizeWalk(s, s.pool[p + i], level, stamp, any);
        return;
    }
}

/**
 * Instantiate the scheme `t`: every quantified variable is replaced by one
 * fresh variable at `level`. Sub-terms with nothing quantified inside are
 * shared with the original, and each node is copied at most once.
 */
TypeId instantiate(TypeStore s, TypeId t, int level)
{
    return instWalk(s, t, level, s.newStamp());
}

private TypeId instWalk(TypeStore s, TypeId t, int level, ulong stamp)
{
    t = s.find(t);
    final switch (s.nodes[t].kind)
    {
    case NodeKind.variable:
        if (s.nodes[t].level != genericLevel)
            return t;
        if (s.nodes[t].stamp == stamp)
            return s.nodes[t].memo;
        immutable fresh = s.newVar(level);
        s.nodes[t].stamp = stamp;
        s.nodes[t].memo = fresh;
        return fresh;
    case NodeKind.int_, NodeKind.bool_, NodeKind.unit:
        return t;
    case NodeKind.arrow:
    {
        if (s.nodes[t].stamp == stamp)
            return s.nodes[t].memo;
        immutable oa = s.find(s.nodes[t].a);
        immutable ob = s.find(s.nodes[t].b);
        immutable na = instWalk(s, oa, level, stamp);
        immutable nb = instWalk(s, ob, level, stamp);
        immutable r = (na == oa && nb == ob) ? t : s.newArrow(na, nb);
        s.nodes[t].stamp = stamp;
        s.nodes[t].memo = r;
        return r;
    }
    case NodeKind.list:
    {
        if (s.nodes[t].stamp == stamp)
            return s.nodes[t].memo;
        immutable oe = s.find(s.nodes[t].a);
        immutable ne = instWalk(s, oe, level, stamp);
        immutable r = ne == oe ? t : s.newList(ne);
        s.nodes[t].stamp = stamp;
        s.nodes[t].memo = r;
        return r;
    }
    case NodeKind.tuple:
    {
        if (s.nodes[t].stamp == stamp)
            return s.nodes[t].memo;
        immutable n = s.nodes[t].b;
        immutable p = s.nodes[t].a;
        int newStart = -1; // allocated lazily, once a component changes
        foreach (i; 0 .. n)
        {
            immutable oc = s.find(s.pool[p + i]);
            immutable nc = instWalk(s, oc, level, stamp);
            if (newStart < 0 && nc != oc)
            {
                newStart = s.allocPool(n);
                foreach (j; 0 .. i)
                    s.pool[newStart + j] = s.find(s.pool[p + j]);
            }
            if (newStart >= 0)
                s.pool[newStart + i] = nc;
        }
        immutable r = newStart < 0 ? t : s.newTupleAt(newStart, n);
        s.nodes[t].stamp = stamp;
        s.nodes[t].memo = r;
        return r;
    }
    }
}

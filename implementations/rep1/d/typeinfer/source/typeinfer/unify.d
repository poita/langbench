/**
 * Destructive unification with a fused occurs check and level adjustment.
 */
module typeinfer.unify;

import typeinfer.errors;
import typeinfer.types;

/**
 * Make `x` and `y` equal by linking variables.
 *
 * Constructor children are unified left to right, each fully before the
 * next. The first failure throws a `TypeError` of kind `unify` or `occurs`;
 * bindings made before the failure are not undone (the caller discards the
 * whole declaration).
 */
void unify(TypeStore s, TypeId x, TypeId y)
{
    while (true)
    {
        x = s.find(x);
        y = s.find(y);
        if (x == y)
            return;
        immutable kx = s.nodes[x].kind;
        immutable ky = s.nodes[y].kind;
        if (kx == NodeKind.variable)
        {
            bindVariable(s, x, y);
            return;
        }
        if (ky == NodeKind.variable)
        {
            bindVariable(s, y, x);
            return;
        }
        if (kx != ky)
            throw new TypeError(ErrorKind.unify);
        final switch (kx)
        {
        case NodeKind.variable, NodeKind.int_, NodeKind.bool_, NodeKind.unit:
            // Singletons are equal iff identical, which was handled above.
            throw new TypeError(ErrorKind.unify);
        case NodeKind.arrow:
            unify(s, s.nodes[x].a, s.nodes[y].a);
            x = s.nodes[x].b; // continue with the results
            y = s.nodes[y].b;
            break;
        case NodeKind.list:
            x = s.nodes[x].a;
            y = s.nodes[y].a;
            break;
        case NodeKind.tuple:
        {
            immutable n = s.nodes[x].b;
            if (n != s.nodes[y].b)
                throw new TypeError(ErrorKind.unify);
            immutable px = s.nodes[x].a;
            immutable py = s.nodes[y].a;
            foreach (i; 0 .. n - 1)
                unify(s, s.pool[px + i], s.pool[py + i]);
            x = s.pool[px + n - 1];
            y = s.pool[py + n - 1];
            break;
        }
        }
    }
}

/// Bind the unbound variable `v` to `t`, after the occurs check.
private void bindVariable(TypeStore s, TypeId v, TypeId t)
{
    occursAdjust(s, v, t, s.nodes[v].level, s.newStamp());
    s.nodes[v].a = t;
}

/// Fail with `occurs` if `v` occurs in `t`; lower every variable's level to at most `level`.
private void occursAdjust(TypeStore s, TypeId v, TypeId t, int level, ulong stamp)
{
    t = s.find(t);
    if (t == v)
        throw new TypeError(ErrorKind.occurs);
    final switch (s.nodes[t].kind)
    {
    case NodeKind.variable:
        if (s.nodes[t].level > level)
            s.nodes[t].level = level;
        return;
    case NodeKind.int_, NodeKind.bool_, NodeKind.unit:
        return;
    case NodeKind.arrow:
        if (s.nodes[t].stamp == stamp)
            return;
        s.nodes[t].stamp = stamp;
        occursAdjust(s, v, s.nodes[t].a, level, stamp);
        occursAdjust(s, v, s.nodes[t].b, level, stamp);
        return;
    case NodeKind.list:
        if (s.nodes[t].stamp == stamp)
            return;
        s.nodes[t].stamp = stamp;
        occursAdjust(s, v, s.nodes[t].a, level, stamp);
        return;
    case NodeKind.tuple:
        if (s.nodes[t].stamp == stamp)
            return;
        s.nodes[t].stamp = stamp;
        immutable p = s.nodes[t].a;
        foreach (i; 0 .. s.nodes[t].b)
            occursAdjust(s, v, s.pool[p + i], level, stamp);
        return;
    }
}

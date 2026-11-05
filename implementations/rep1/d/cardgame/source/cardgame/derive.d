/**
 * The layer system (SPEC 14): derivation of current controllers, keywords,
 * edge and core for every Field object from the live continuous-effect records.
 */
module cardgame.derive;

import cardgame.cards;
import cardgame.eval;
import cardgame.game;

/// Re-derive characteristics if anything they depend on has changed.
void ensureDerived(Game g)
{
    if (g.stale && !g.deriving)
        derive(g);
}

/// Whole-board derivation following SPEC 14.3.
void derive(Game g)
{
    g.deriving = true;
    scope (exit)
    {
        g.deriving = false;
        g.stale = false;
    }

    // Reset every Field object to its printed characteristics.
    foreach (oid; g.field)
    {
        auto o = &g.objs[oid];
        auto card = g.db.cards[o.card];
        o.cur = o.ctrl;
        o.stripped = false;
        o.edge = card.edge;
        o.core = card.core;
        o.kws.length = 0;
        o.kws ~= card.keywords;
    }

    // Layer 1: control; then which objects are stripped.
    foreach (r; g.recs)
    {
        if (r.aura)
            continue;
        if (r.kind == RecKind.control)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                    g.objs[a].cur = cast(ubyte) r.ctrl;
        }
        else if (r.kind == RecKind.strip)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                    g.objs[a].stripped = true;
        }
    }

    // Aura records: activity, arguments and affected lists.
    uint deps = 0;
    foreach (r; g.recs)
        if (r.aura)
        {
            evalAura(g, r);
            deps |= r.ability.deps;
        }
    g.liveDeps = deps;

    // Layer 2: keywords.
    foreach (r; g.recs)
    {
        if (r.aura)
        {
            foreach (ref l; r.leaves)
                if (l.active && l.kind == StKind.grant)
                    foreach (a; l.affected)
                        g.objs[a].kws ~= l.kw;
        }
        else if (r.kind == RecKind.grant)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                    g.objs[a].kws ~= r.kw;
        }
        else if (r.kind == RecKind.strip)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                    g.objs[a].kws.length = 0;
        }
    }

    // Layer 3: setbody.
    foreach (r; g.recs)
    {
        if (r.aura)
        {
            foreach (ref l; r.leaves)
                if (l.active && l.kind == StKind.setbody)
                    foreach (a; l.affected)
                    {
                        g.objs[a].edge = l.a;
                        g.objs[a].core = l.b;
                    }
        }
        else if (r.kind == RecKind.setbody)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                {
                    g.objs[a].edge = r.a;
                    g.objs[a].core = r.b;
                }
        }
    }

    // Layer 4: modify.
    foreach (r; g.recs)
    {
        if (r.aura)
        {
            foreach (ref l; r.leaves)
                if (l.active && l.kind == StKind.modify)
                    foreach (a; l.affected)
                    {
                        g.objs[a].edge += l.a;
                        g.objs[a].core += l.b;
                    }
        }
        else if (r.kind == RecKind.modify)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                {
                    g.objs[a].edge += r.a;
                    g.objs[a].core += r.b;
                }
        }
    }

    // Layer 5: charge counters.
    foreach (oid; g.field)
    {
        auto o = &g.objs[oid];
        o.edge += o.counters;
        o.core += o.counters;
    }

    // Layer 6: swapstats.
    foreach (r; g.recs)
    {
        if (r.aura)
        {
            foreach (ref l; r.leaves)
                if (l.active && l.kind == StKind.swapstats)
                    foreach (a; l.affected)
                    {
                        auto o = &g.objs[a];
                        immutable t = o.edge;
                        o.edge = o.core;
                        o.core = t;
                    }
        }
        else if (r.kind == RecKind.swapstats)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                {
                    auto o = &g.objs[a];
                    immutable t = o.edge;
                    o.edge = o.core;
                    o.core = t;
                }
        }
    }
}

private void evalAura(Game g, Rec r)
{
    r.ctrl = g.objs[r.src].cur;
    r.leaves.length = 0;
    auto c = Ctx(r.ctrl, r.src);
    c.inAura = true;
    immutable base = !g.objs[r.src].stripped;
    foreach (st; r.ability.statics)
        evalStatic(g, r, st, base, c);
}

private void evalStatic(Game g, Rec r, Static st, bool active, ref Ctx c)
{
    if (st.kind == StKind.when)
    {
        immutable holds = condVal(g, st.cond, c);
        foreach (s; st.subs)
            evalStatic(g, r, s, active && holds, c);
        return;
    }
    Leaf l;
    l.kind = st.kind;
    l.active = active;
    switch (st.kind)
    {
    case StKind.modify:
    case StKind.setbody:
        l.a = amtVal(g, st.a, c);
        l.b = amtVal(g, st.b, c);
        break;
    case StKind.grant:
        l.kw = st.kw;
        break;
    case StKind.cheaper:
        l.n = st.n;
        l.cardFilters = st.cardFilters;
        break;
    default:
        break;
    }
    if (active && st.kind != StKind.cheaper)
    {
        int[] objs;
        selObjs(g, st.sel, c, objs);
        foreach (o; objs)
            if (g.objs[o].zone == ZoneKind.field)
                l.affected ~= o;
    }
    r.leaves ~= l;
}

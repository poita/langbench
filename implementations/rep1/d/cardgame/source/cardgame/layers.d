/**
 * The layer engine: whole-board derivation of current characteristics from
 * printed ones (SPEC.md section 14), plus aura-record bookkeeping.
 */
module cardgame.layers;

import cardgame.game;
import cardgame.model;
import cardgame.select;

/// Re-derive the board if anything it can depend on has changed.
void ensureDerived(Game g)
{
    if (g.dirty && !g.deriving) derive(g);
}

/// Create the aura records of an object that has just entered the Field (14.2).
void createAuraRecords(Game g, Obj o)
{
    foreach (ab; o.card.abilities)
    {
        if (ab.kind != AbilityKind.aura) continue;
        auto r = new Record;
        r.eid = g.nextEid++;
        r.ts = g.takeTs();
        r.src = o;
        r.aura = true;
        r.ability = ab;
        r.ctrl = o.ctrl;
        g.records ~= r;
    }
    g.dirty = true;
}

/// Remove the aura records whose source is `o`.
void removeAuraRecords(Game g, Obj o)
{
    size_t j = 0;
    foreach (r; g.records)
        if (!(r.aura && r.src is o)) g.records[j++] = r;
    g.records.length = j;
    g.dirty = true;
}

private void collectStatics(Game g, const Static s, bool condOk, ref Ctx c, ref RecPart[] parts)
{
    final switch (s.kind)
    {
    case Static.Kind.when:
    {
        immutable ok = evalCond(g, s.cond, c);
        foreach (i; s.inner) collectStatics(g, i, condOk && ok, c, parts);
        break;
    }
    case Static.Kind.modify:
    case Static.Kind.setbody:
    {
        RecPart p;
        p.kind = s.kind == Static.Kind.modify ? RecKind.modify : RecKind.setbody;
        p.a = evalAmount(g, s.amt, c);
        p.b = evalAmount(g, s.amt2, c);
        p.active = condOk;
        if (condOk) p.affected = selectObjs(g, s.sel, c);
        parts ~= p;
        break;
    }
    case Static.Kind.swapstats:
    {
        RecPart p;
        p.kind = RecKind.swapstats;
        p.active = condOk;
        if (condOk) p.affected = selectObjs(g, s.sel, c);
        parts ~= p;
        break;
    }
    case Static.Kind.grant:
    {
        RecPart p;
        p.kind = RecKind.grant;
        p.kw = s.kw;
        p.active = condOk;
        if (condOk) p.affected = selectObjs(g, s.sel, c);
        parts ~= p;
        break;
    }
    case Static.Kind.cheaper:
    {
        RecPart p;
        p.kind = RecKind.cheaper;
        p.cheaperBy = s.cheaperBy;
        p.cardFilters = cast(Filter[]) s.cardFilters;
        p.active = condOk;
        parts ~= p;
        break;
    }
    }
}

/// Derive current characteristics for every Field object (14.3).
void derive(Game g)
{
    g.deriving = true;
    scope (exit) { g.deriving = false; g.dirty = false; }

    foreach (o; g.field)
    {
        o.ctrl = o.baseCtrl;
        o.stripped = false;
        o.kwMask = o.card.kwMask;
        int p = 0;
        foreach (k; o.card.keywords) if (k.kw == Kw.plating) p += k.value;
        o.platingSum = p;
        o.edge = o.card.edge;
        o.core = o.card.core;
    }

    // 1. layer 1: control
    foreach (r; g.records)
        if (!r.aura && r.kind == RecKind.control)
            foreach (oid; r.affected)
            {
                auto o = g.objs[oid];
                if (o.zone == Zone.field) o.ctrl = r.ctrl;
            }

    // 2. stripped objects
    foreach (r; g.records)
        if (!r.aura && r.kind == RecKind.strip)
            foreach (oid; r.affected)
            {
                auto o = g.objs[oid];
                if (o.zone == Zone.field) o.stripped = true;
            }

    // 3. aura records: activity, affected lists, arguments
    foreach (r; g.records)
    {
        if (!r.aura) continue;
        r.parts.length = 0;
        auto src = r.src;
        r.ctrl = src.ctrl;
        Ctx c = Ctx(src.ctrl, src);
        c.aura = true;
        foreach (s; r.ability.statics) collectStatics(g, s, !src.stripped, c, r.parts);
    }

    // 4. layer 2: grant / strip
    foreach (r; g.records)
    {
        if (r.aura)
        {
            foreach (ref p; r.parts)
                if (p.kind == RecKind.grant && p.active)
                    foreach (o; p.affected) addKeyword(o, p.kw);
        }
        else if (r.kind == RecKind.grant)
        {
            foreach (oid; r.affected)
            {
                auto o = g.objs[oid];
                if (o.zone == Zone.field) addKeyword(o, r.kw);
            }
        }
        else if (r.kind == RecKind.strip)
        {
            foreach (oid; r.affected)
            {
                auto o = g.objs[oid];
                if (o.zone == Zone.field) { o.kwMask = 0; o.platingSum = 0; }
            }
        }
    }

    // 5. layers 3 and 4, counters, layer 6
    applyLayer(g, RecKind.setbody);
    applyLayer(g, RecKind.modify);
    foreach (o; g.field)
    {
        o.edge += o.counters;
        o.core += o.counters;
    }
    applyLayer(g, RecKind.swapstats);
}

private void addKeyword(Obj o, KwSpec k)
{
    o.kwMask |= 1u << k.kw;
    if (k.kw == Kw.plating) o.platingSum += k.value;
}

private void applyOne(Obj o, RecKind kind, long a, long b)
{
    final switch (kind)
    {
    case RecKind.setbody: o.edge = a; o.core = b; break;
    case RecKind.modify: o.edge += a; o.core += b; break;
    case RecKind.swapstats: auto t = o.edge; o.edge = o.core; o.core = t; break;
    case RecKind.grant: case RecKind.strip: case RecKind.control: case RecKind.cheaper: break;
    }
}

private void applyLayer(Game g, RecKind kind)
{
    foreach (r; g.records)
    {
        if (r.aura)
        {
            foreach (ref p; r.parts)
                if (p.kind == kind && p.active)
                    foreach (o; p.affected) applyOne(o, kind, p.a, p.b);
        }
        else if (r.kind == kind)
        {
            foreach (oid; r.affected)
            {
                auto o = g.objs[oid];
                if (o.zone == Zone.field) applyOne(o, kind, r.a, r.b);
            }
        }
    }
}

/// Total `cheaper` reduction for `player` playing a card (11.2 step 4).
long cheaperTotal(Game g, Player player, Card card)
{
    ensureDerived(g);
    long total = 0;
    foreach (r; g.records)
    {
        if (!r.aura || r.ctrl != player) continue;
        foreach (ref p; r.parts)
        {
            if (p.kind != RecKind.cheaper || !p.active) continue;
            bool ok = true;
            foreach (f; p.cardFilters)
            {
                final switch (f.kind)
                {
                case Filter.Kind.type: ok = ok && card.type == f.type; break;
                case Filter.Kind.tag:
                    bool has;
                    foreach (t; card.tags) if (t == f.tag) has = true;
                    ok = ok && has;
                    break;
                case Filter.Kind.cost: ok = ok && compare(card.cost, f.cmp, f.n); break;
                case Filter.Kind.kw, Filter.Kind.noKw, Filter.Kind.edge, Filter.Kind.core,
                     Filter.Kind.wounded, Filter.Kind.ready, Filter.Kind.exhausted,
                     Filter.Kind.settling, Filter.Kind.attacking, Filter.Kind.blocking,
                     Filter.Kind.mine, Filter.Kind.enemy, Filter.Kind.other, Filter.Kind.not:
                    ok = false;
                    break;
                }
            }
            if (ok) total += p.cheaperBy;
        }
    }
    return total;
}

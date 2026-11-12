/**
 * Evaluation of filters, selectors, amounts and conditions (SPEC.md 6.3-6.7)
 * and the targeting rules of section 12.
 */
module cardgame.select;

import std.algorithm : sort, SwapStrategy;
import cardgame.game;
import cardgame.layers;
import cardgame.model;

/// The evaluation context of an ability.
struct Ctx
{
    Player ctrl;            /// the ability's controller
    Obj src;                /// the source object
    Entry ent;              /// the entry whose targets `(t n)` refers to
    Subject it;             /// trigger subject
    Obj that;               /// innermost `each` binding
    bool aura;              /// aura mode: base values only, no re-derivation
}

/// Base edge: printed edge plus charge counters.
long baseEdge(const Obj o) { return o.card.edge + (o.zone == Zone.field ? o.counters : 0); }

/// Base core: printed core plus charge counters.
long baseCore(const Obj o) { return o.card.core + (o.zone == Zone.field ? o.counters : 0); }

/// Current edge (derived on the Field, printed elsewhere).
long curEdge(Game g, Obj o)
{
    if (o.zone != Zone.field) return o.card.edge;
    ensureDerived(g);
    return o.edge;
}

/// Current core.
long curCore(Game g, Obj o)
{
    if (o.zone != Zone.field) return o.card.core;
    ensureDerived(g);
    return o.core;
}

/// Current keyword test.
bool curHas(Game g, Obj o, Kw k)
{
    if (o.zone != Zone.field) return o.card.hasKeyword(k);
    ensureDerived(g);
    return o.has(k);
}

/// Controller for Field objects, owner elsewhere (the `mine` / scope rule).
Player scopeOwner(const Obj o) { return o.zone == Zone.field ? o.ctrl : o.owner; }

/// Whether an object with `owner` satisfies a selector scope for controller `c`.
bool inScope(Scope s, Player owner, Player c)
{
    final switch (s)
    {
    case Scope.yours: return owner == c;
    case Scope.theirs: return owner != c;
    case Scope.all: return true;
    }
}

/// Canonical object order: ascending (timestamp, oid).
bool canonLess(const Obj a, const Obj b) { return a.ts < b.ts || (a.ts == b.ts && a.oid < b.oid); }

/// Sort objects into canonical order.
void sortCanon(Obj[] a) { a.sort!(canonLess, SwapStrategy.stable); }

// ------------------------------------------------------------------ filters

/// Whether `o` satisfies a filter (base characteristics, section 6.2).
bool matchFilter(Game g, Obj o, const Filter f, in Ctx c)
{
    final switch (f.kind)
    {
    case Filter.Kind.kw: return o.card.hasKeyword(f.kw);
    case Filter.Kind.noKw: return !o.card.hasKeyword(f.kw);
    case Filter.Kind.tag:
        foreach (t; o.card.tags) if (t == f.tag) return true;
        return false;
    case Filter.Kind.type: return o.card.type == f.type;
    case Filter.Kind.cost: return compare(o.card.cost, f.cmp, f.n);
    case Filter.Kind.edge: return compare(baseEdge(o), f.cmp, f.n);
    case Filter.Kind.core: return compare(baseCore(o), f.cmp, f.n);
    case Filter.Kind.wounded: return o.zone == Zone.field && o.wounds > 0;
    case Filter.Kind.ready: return o.zone == Zone.field && !o.exhausted;
    case Filter.Kind.exhausted: return o.zone == Zone.field && o.exhausted;
    case Filter.Kind.settling: return o.zone == Zone.field && isSettling(g, o);
    case Filter.Kind.attacking: return o.zone == Zone.field && o.attacking;
    case Filter.Kind.blocking: return o.zone == Zone.field && o.blocking;
    case Filter.Kind.mine: return scopeOwner(o) == c.ctrl;
    case Filter.Kind.enemy: return scopeOwner(o) != c.ctrl;
    case Filter.Kind.other: return o !is c.src;
    case Filter.Kind.not: return !matchFilter(g, o, f.inner, c);
    }
}

/// Whether all filters hold.
bool matchAll(Game g, Obj o, const Filter[] fs, in Ctx c)
{
    foreach (f; fs) if (!matchFilter(g, o, f, c)) return false;
    return true;
}

/// Settling (16.1): on the Field and `since >= turn`.
bool isSettling(Game g, const Obj o) { return o.zone == Zone.field && o.since >= g.turn; }

// ------------------------------------------------------------------ selectors

/// Evaluate an object selector; the result is in canonical object order.
Obj[] selectObjs(Game g, const Selector s, ref Ctx c)
{
    if (!c.aura) ensureDerived(g);
    final switch (s.kind)
    {
    case Selector.Kind.self: return c.src is null ? null : [c.src];
    case Selector.Kind.it:
        if (c.it.kind == Subject.Kind.obj) return [g.obj(c.it.id)];
        return null;
    case Selector.Kind.that: return c.that is null ? null : [c.that];
    case Selector.Kind.target:
        if (c.ent !is null && s.n <= c.ent.targets.length)
        {
            auto t = c.ent.targets[s.n - 1];
            if (t.kind == Target.Kind.obj && !t.removed) return [g.obj(t.id)];
        }
        return null;
    case Selector.Kind.units: return fieldMatches(g, s, c, CardType.unit);
    case Selector.Kind.relics: return fieldMatches(g, s, c, CardType.relic);
    case Selector.Kind.cards:
    {
        Obj[] r;
        foreach (p; [Player.A, Player.B])
        {
            if (!inScope(s.scope_, p, c.ctrl)) continue;
            Obj[] zone;
            final switch (s.zone)
            {
            case Zone.hand: zone = g.pl[p].hand; break;
            case Zone.ash: zone = g.pl[p].ash; break;
            case Zone.rift: zone = g.pl[p].rift; break;
            case Zone.vault: zone = g.pl[p].vault.items; break;
            case Zone.none: case Zone.field: case Zone.chain: break;
            }
            foreach (o; zone) if (matchAll(g, o, s.filters, c)) r ~= o;
        }
        sortCanon(r);
        return r;
    }
    case Selector.Kind.randomUnit:
    {
        auto list = fieldMatches(g, s, c, CardType.unit);
        if (list.length == 0) return null;
        return [list[cast(size_t) g.rng.below(list.length)]];
    }
    }
}

private Obj[] fieldMatches(Game g, const Selector s, in Ctx c, CardType t)
{
    Obj[] r;
    foreach (o; g.field)
    {
        if (o.card.type != t) continue;
        if (!inScope(s.scope_, o.ctrl, c.ctrl)) continue;
        if (matchAll(g, o, s.filters, c)) r ~= o;
    }
    return r;
}

/// Evaluate a player selector (A before B).
Player[] selectPlayers(Game g, const PSel s, ref Ctx c)
{
    final switch (s.kind)
    {
    case PSel.Kind.you: return [c.ctrl];
    case PSel.Kind.foe: return [opponent(c.ctrl)];
    case PSel.Kind.both: return [Player.A, Player.B];
    case PSel.Kind.target:
        if (c.ent !is null && s.n <= c.ent.targets.length)
        {
            auto t = c.ent.targets[s.n - 1];
            if (t.kind == Target.Kind.player && !t.removed) return [cast(Player) t.id];
        }
        return null;
    case PSel.Kind.ownerOf:
    {
        if (s.inner.kind == Selector.Kind.target && c.ent !is null && s.inner.n <= c.ent.targets.length)
        {
            auto t = c.ent.targets[s.inner.n - 1];
            if (t.kind == Target.Kind.player)
                return t.removed ? null : [cast(Player) t.id];
        }
        bool[2] seen;
        foreach (o; selectObjs(g, s.inner, c)) seen[o.owner] = true;
        Player[] r;
        if (seen[0]) r ~= Player.A;
        if (seen[1]) r ~= Player.B;
        return r;
    }
    }
}

// ------------------------------------------------------------------ amounts / conditions

private long sumHand(Game g, Player[] ps) { long n; foreach (p; ps) n += g.pl[p].hand.length; return n; }
private long sumAsh(Game g, Player[] ps) { long n; foreach (p; ps) n += g.pl[p].ash.length; return n; }
private long sumVault(Game g, Player[] ps) { long n; foreach (p; ps) n += g.pl[p].vault.length; return n; }

/// Evaluate an amount.
long evalAmount(Game g, const Amount a, ref Ctx c)
{
    final switch (a.kind)
    {
    case Amount.Kind.literal: return a.value;
    case Amount.Kind.count: return selectObjs(g, a.sel, c).length;
    case Amount.Kind.hand: return sumHand(g, selectPlayers(g, a.psel, c));
    case Amount.Kind.ash: return sumAsh(g, selectPlayers(g, a.psel, c));
    case Amount.Kind.vault: return sumVault(g, selectPlayers(g, a.psel, c));
    case Amount.Kind.edge:
    {
        long n;
        foreach (o; selectObjs(g, a.sel, c)) n += c.aura ? baseEdge(o) : curEdge(g, o);
        return n;
    }
    case Amount.Kind.core:
    {
        long n;
        foreach (o; selectObjs(g, a.sel, c)) n += c.aura ? baseCore(o) : curCore(g, o);
        return n;
    }
    case Amount.Kind.wounds:
    {
        long n;
        foreach (o; selectObjs(g, a.sel, c)) n += o.zone == Zone.field ? o.wounds : 0;
        return n;
    }
    }
}

/// Evaluate a condition.
bool evalCond(Game g, const Cond k, ref Ctx c)
{
    final switch (k.kind)
    {
    case Cond.Kind.count: return compare(selectObjs(g, k.sel, c).length, k.cmp, k.value);
    case Cond.Kind.spire:
    {
        long n;
        foreach (p; selectPlayers(g, k.psel, c)) n += g.pl[p].spire;
        return compare(n, k.cmp, k.value);
    }
    case Cond.Kind.hand: return compare(sumHand(g, selectPlayers(g, k.psel, c)), k.cmp, k.value);
    case Cond.Kind.ash: return compare(sumAsh(g, selectPlayers(g, k.psel, c)), k.cmp, k.value);
    case Cond.Kind.vault: return compare(sumVault(g, selectPlayers(g, k.psel, c)), k.cmp, k.value);
    case Cond.Kind.ember:
    {
        long n;
        foreach (p; selectPlayers(g, k.psel, c)) n += g.pl[p].ember;
        return compare(n, k.cmp, k.value);
    }
    case Cond.Kind.myturn: return g.active == c.ctrl;
    case Cond.Kind.and:
        foreach (s; k.subs) if (!evalCond(g, s, c)) return false;
        return true;
    case Cond.Kind.or:
        foreach (s; k.subs) if (evalCond(g, s, c)) return true;
        return false;
    case Cond.Kind.not: return !evalCond(g, k.subs[0], c);
    }
}

// ------------------------------------------------------------------ targeting

/// Sort key of a target (12.4).
long[3] targetKey(Game g, in Target t)
{
    final switch (t.kind)
    {
    case Target.Kind.player: return [0, t.id, 0];
    case Target.Kind.obj: auto o = g.obj(t.id); return [1, o.ts, o.oid];
    case Target.Kind.chain: return [2, t.id, 0];
    }
}

/// Ordering of targets by key.
bool targetLess(Game g, in Target a, in Target b) { return targetKey(g, a) < targetKey(g, b); }

/// Whether the object is a unit on the Field that the spectral rule protects from `ctrl`.
bool spectralProtected(Game g, Obj o, Player ctrl)
{
    return o.zone == Zone.field && o.isUnit && curHas(g, o, Kw.spectral) && o.ctrl != ctrl;
}

private bool legalUnitTarget(Game g, Obj o, const Filter[] fs, Player ctrl, Obj src)
{
    if (o is null || o.zone != Zone.field || !o.isUnit) return false;
    ensureDerived(g);
    Ctx c = Ctx(ctrl, src);
    if (!matchAll(g, o, fs, c)) return false;
    return !spectralProtected(g, o, ctrl);
}

/// Whether `t` is a legal target for `spec` (12.1, 12.2). `selfCid` is the entry being announced.
bool targetLegal(Game g, const TSpec spec, in Target t, Player ctrl, Obj src, int selfCid)
{
    final switch (spec.kind)
    {
    case TSpec.Kind.unit:
        return t.kind == Target.Kind.obj && legalUnitTarget(g, g.obj(t.id), spec.filters, ctrl, src);
    case TSpec.Kind.relic:
    {
        if (t.kind != Target.Kind.obj) return false;
        auto o = g.obj(t.id);
        if (o is null || o.zone != Zone.field || o.card.type != CardType.relic) return false;
        Ctx c = Ctx(ctrl, src);
        return matchAll(g, o, spec.filters, c);
    }
    case TSpec.Kind.any:
        if (t.kind == Target.Kind.player) return true;
        return t.kind == Target.Kind.obj && legalUnitTarget(g, g.obj(t.id), spec.filters, ctrl, src);
    case TSpec.Kind.player: return t.kind == Target.Kind.player;
    case TSpec.Kind.chained:
        return t.kind == Target.Kind.chain && t.id != selfCid && g.entryByCid(t.id) !is null;
    case TSpec.Kind.ashcard:
    {
        if (t.kind != Target.Kind.obj) return false;
        auto o = g.obj(t.id);
        if (o is null || o.zone != Zone.ash) return false;
        Ctx c = Ctx(ctrl, src);
        return matchAll(g, o, spec.filters, c);
    }
    }
}

/// All legal targets for `spec` in ascending key order.
Target[] candidates(Game g, const TSpec spec, Player ctrl, Obj src, int selfCid)
{
    Target[] r;
    final switch (spec.kind)
    {
    case TSpec.Kind.unit:
    case TSpec.Kind.relic:
    case TSpec.Kind.any:
        if (spec.kind == TSpec.Kind.any) r ~= [Target.ofPlayer(Player.A), Target.ofPlayer(Player.B)];
        foreach (o; g.field)
        {
            auto t = Target.ofObj(o.oid);
            if (targetLegal(g, spec, t, ctrl, src, selfCid)) r ~= t;
        }
        break;
    case TSpec.Kind.player:
        r = [Target.ofPlayer(Player.A), Target.ofPlayer(Player.B)];
        break;
    case TSpec.Kind.chained:
        foreach (e; g.chain)
            if (e.cid != selfCid) r ~= Target.ofChain(e.cid);
        r.sort!((a, b) => a.id < b.id);
        break;
    case TSpec.Kind.ashcard:
    {
        Obj[] cs;
        foreach (p; [Player.A, Player.B])
            foreach (o; g.pl[p].ash)
            {
                Ctx c = Ctx(ctrl, src);
                if (matchAll(g, o, spec.filters, c)) cs ~= o;
            }
        sortCanon(cs);
        foreach (o; cs) r ~= Target.ofObj(o.oid);
        break;
    }
    }
    return r;
}

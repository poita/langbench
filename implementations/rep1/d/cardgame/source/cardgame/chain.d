/**
 * Playing cards, activating abilities, and resolving Chain entries
 * (SPEC.md sections 11 and 12).
 */
module cardgame.chain;

import std.algorithm : max;
import std.conv : to;
import cardgame.effects;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.procs;
import cardgame.select;
import cardgame.triggers;

/// A target token as written in a script command.
struct Tok
{
    Target.Kind kind;
    ulong id;
}

/// Convert a token to a target; false when it cannot name anything existing.
private bool tokToTarget(Game g, in Tok t, out Target r)
{
    final switch (t.kind)
    {
    case Target.Kind.player:
        r = Target.ofPlayer(cast(Player) t.id);
        return true;
    case Target.Kind.obj:
        if (g.obj(cast(long) t.id) is null || t.id > int.max) return false;
        r = Target.ofObj(cast(int) t.id);
        return true;
    case Target.Kind.chain:
        if (t.id > int.max || g.entryByCid(cast(long) t.id) is null) return false;
        r = Target.ofChain(cast(int) t.id);
        return true;
    }
}

/// Check the supplied targets against the specs; returns an error kind or null.
string checkTargets(Game g, TSpec[] specs, in Tok[] toks, Player ctrl, Obj src, out Target[] ts)
{
    if (toks.length != specs.length) return "bad-target-count";
    bool ok = true;
    foreach (i, tk; toks)
    {
        Target t;
        if (!tokToTarget(g, tk, t)) { ok = false; ts ~= Target.init; continue; }
        ts ~= t;
    }
    if (!ok) return "illegal-target";
    foreach (i, t; ts)
    {
        foreach (j; 0 .. i)
            if (ts[j].kind == t.kind && ts[j].id == t.id) return "illegal-target";
        if (!targetLegal(g, specs[i], t, ctrl, src, g.nextCid)) return "illegal-target";
    }
    return null;
}

/// 11.1: may `card` be played by `p` right now (given that `p` holds priority)?
bool playTimingOk(Game g, Player p, Card card)
{
    if (card.type == CardType.rite && card.hasKeyword(Kw.swift)) return true;
    return g.active == p && (g.phase == "main1" || g.phase == "main2") && g.chain.length == 0;
}

/// Ember cost of playing `card` for `p` (11.2 step 4).
long playCost(Game g, Player p, Card card)
{
    return max(0L, card.cost - cheaperTotal(g, p, card));
}

/// Target specifications of a hand card (those of its `resolve` clause).
TSpec[] playSpecs(Card c)
{
    if (c.type == CardType.rite && c.abilities.length > 0 && c.abilities[0].kind == AbilityKind.resolve)
        return c.abilities[0].targets;
    return null;
}

/// Validate a `PLAY`; returns the error kind or null.
string checkPlay(Game g, Player p, ulong pos, in Tok[] toks, out Target[] ts, out long cost)
{
    auto hand = g.pl[p].hand;
    if (pos == 0 || pos > hand.length) return "no-such-card";
    auto o = hand[cast(size_t) pos - 1];
    if (!playTimingOk(g, p, o.card)) return "bad-timing";
    auto err = checkTargets(g, playSpecs(o.card), toks, p, o, ts);
    if (err !is null) return err;
    cost = playCost(g, p, o.card);
    if (g.pl[p].ember < cost) return "cannot-afford";
    return null;
}

/// Perform a validated `PLAY` (11.2 steps 2, 5-7).
void doPlay(Game g, Player p, size_t pos, Target[] ts, long cost)
{
    auto o = g.pl[p].hand[pos - 1];
    g.unplace(o);
    o.zone = Zone.chain;
    auto e = new Entry;
    e.cid = g.nextCid++;
    e.kind = o.card.type == CardType.unit ? EntryKind.unit
           : o.card.type == CardType.rite ? EntryKind.rite : EntryKind.relic;
    e.ctrl = p;
    e.src = o;
    e.targets = ts;
    e.specs = playSpecs(o.card);
    g.chain ~= e;
    string line = "PLAY " ~ Game.r(p) ~ " ~" ~ e.cid.to!string ~ " " ~ Game.r(o) ~ " " ~ o.card.id;
    foreach (t; ts) line ~= " " ~ g.render(t);
    g.rawEvent(line);
    g.pl[p].ember -= cost;
    g.dirty = true;
    if (cost > 0) g.emit("PAY", Game.r(p), "ember", cost);
    if (o.card.type == CardType.rite)
        evPlayerEvent(g, p, Event.youPlayRite, Event.enemyPlaysRite, Subject.ofObj(o.oid));
}

/// Whether one cost item can be paid by `p` for ability `abilityIndex` of `o` (11.3 step 4).
bool costOk(Game g, Player p, Obj o, in CostItem c, int abilityIndex)
{
    final switch (c.kind)
    {
    case CostItem.Kind.ember: return g.pl[p].ember >= c.n;
    case CostItem.Kind.spire: return true;
    case CostItem.Kind.discard: return g.pl[p].hand.length >= c.n;
    case CostItem.Kind.exhaust:
        return o.zone == Zone.field && !o.exhausted && (!isSettling(g, o) || curHas(g, o, Kw.vanguard));
    case CostItem.Kind.sacself: return o.zone == Zone.field;
    case CostItem.Kind.counters: return o.zone == Zone.field && o.counters >= c.n;
    case CostItem.Kind.once:
    {
        foreach (i; o.usedOnce) if (i == abilityIndex) return false;
        return true;
    }
    }
}

/// Validate an `ACT`; returns the error kind or null.
string checkAct(Game g, Player p, ulong oid, ulong idx, in Tok[] toks, out Target[] ts, out Ability ab)
{
    ensureDerived(g);
    auto o = oid > int.max ? null : g.obj(cast(long) oid);
    if (o is null || o.zone != Zone.field || o.ctrl != p) return "no-such-object";
    if (idx == 0 || idx > o.card.abilities.length) return "no-such-ability";
    ab = o.card.abilities[cast(size_t) idx - 1];
    if (ab.kind != AbilityKind.act || o.stripped) return "no-such-ability";
    auto err = checkTargets(g, ab.targets, toks, p, o, ts);
    if (err !is null) return err;
    foreach (c; ab.costs) if (!costOk(g, p, o, c, ab.index)) return "cost-unpayable";
    return null;
}

/// Perform a validated `ACT` (11.3 steps 2, 5, 6).
void doAct(Game g, Player p, Obj o, Ability ab, Target[] ts)
{
    auto e = new Entry;
    e.cid = g.nextCid++;
    e.kind = EntryKind.ability;
    e.ctrl = p;
    e.src = o;
    e.abilityIndex = ab.index;
    e.targets = ts;
    e.specs = ab.targets;
    g.chain ~= e;
    string line = "ACTIVATE " ~ Game.r(p) ~ " ~" ~ e.cid.to!string ~ " " ~ Game.r(o) ~ " " ~ ab.index.to!string;
    foreach (t; ts) line ~= " " ~ g.render(t);
    g.rawEvent(line);
    foreach (c; ab.costs)
    {
        final switch (c.kind)
        {
        case CostItem.Kind.ember:
            g.pl[p].ember -= c.n;
            g.dirty = true;
            if (c.n > 0) g.emit("PAY", Game.r(p), "ember", c.n);
            break;
        case CostItem.Kind.spire:
            if (c.n > 0) g.emit("PAY", Game.r(p), "spire", c.n);
            changeSpire(g, p, -c.n);
            break;
        case CostItem.Kind.discard:
            for (long i = 0; i < c.n; ++i) discardTop(g, p);
            break;
        case CostItem.Kind.exhaust: setExhausted(g, o, true); break;
        case CostItem.Kind.sacself: sacrificeObj(g, o); break;
        case CostItem.Kind.counters: changeCounters(g, o, -c.n); break;
        case CostItem.Kind.once: o.usedOnce ~= ab.index; break;
        }
    }
}

/// Remove an entry from the Chain, sending a played card to its owner's Ash (11.5, 17.20).
void negateEntry(Game g, Entry e)
{
    removeEntry(g, e);
    g.emit("NEGATE", "~" ~ e.cid.to!string);
    if (e.kind == EntryKind.rite || e.kind == EntryKind.unit || e.kind == EntryKind.relic)
    {
        g.move(e.src, Zone.ash);
        g.emit("SPENT", Game.r(e.src), e.src.card.id);
    }
}

private void removeEntry(Game g, Entry e)
{
    foreach_reverse (i, x; g.chain)
        if (x is e)
        {
            foreach (j; i + 1 .. g.chain.length) g.chain[j - 1] = g.chain[j];
            g.chain.length = g.chain.length - 1;
            return;
        }
}

/// Resolve the top entry of the Chain (11.6).
void resolveTop(Game g)
{
    auto e = g.chain[$ - 1];
    g.emit("RESOLVE", "~" ~ e.cid.to!string);
    foreach (i, ref t; e.targets)
        t.removed = !targetLegal(g, e.specs[i], t, e.ctrl, e.src, e.cid);
    bool allRemoved = e.targets.length > 0;
    foreach (t; e.targets) if (!t.removed) allRemoved = false;
    Ctx c = Ctx(e.ctrl, e.src, e, e.it);
    if (allRemoved)
        g.emit("FIZZLE", "~" ~ e.cid.to!string);
    else
    {
        final switch (e.kind)
        {
        case EntryKind.rite:
            execEffects(g, e.src.card.abilities[0].effects, c);
            break;
        case EntryKind.unit:
        case EntryKind.relic:
            removeEntry(g, e);
            enterField(g, e.src, e.ctrl);
            break;
        case EntryKind.ability:
        case EntryKind.trigger:
            if (e.delayed) execEffects(g, e.delayedEffects, c);
            else execEffects(g, e.src.card.abilities[e.abilityIndex - 1].effects, c);
            break;
        }
    }
    removeEntry(g, e);
    if (e.kind == EntryKind.rite || (allRemoved && (e.kind == EntryKind.unit || e.kind == EntryKind.relic)))
    {
        g.move(e.src, Zone.ash);
        g.emit("SPENT", Game.r(e.src), e.src.card.id);
    }
}

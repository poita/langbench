/**
 * Triggered abilities: event collection and ordered pushing onto the Chain
 * (SPEC.md section 13).
 */
module cardgame.triggers;

import std.algorithm : sort, SwapStrategy;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.select;

/// Collect the `on <ev>` abilities of `listener`. A listener that is not on the
/// Field, or whose abilities are stripped, does not listen unless `selfLeave`.
void collectFrom(Game g, Obj listener, Event ev, Subject it, bool selfLeave = false)
{
    if (g.quiet) return;
    if (!selfLeave && (listener.zone != Zone.field || listener.stripped)) return;
    foreach (ab; listener.card.abilities)
        if (ab.kind == AbilityKind.on && ab.event == ev)
            g.pending ~= Pending(listener, ab.index, listener.ctrl, listener.ts, it, null);
}

/// `x` has entered the Field (and `ARRIVE` has been emitted).
void evArrive(Game g, Obj x)
{
    if (g.quiet) return;
    ensureDerived(g);
    collectFrom(g, x, Event.arrive, Subject.ofObj(x.oid));
    if (!x.isUnit) return;
    foreach (l; g.field)
    {
        if (l is x) continue;
        collectFrom(g, l, l.ctrl == x.ctrl ? Event.allyArrive : Event.enemyArrive, Subject.ofObj(x.oid));
    }
}

/// `x` has left the Field; `died` for destroy/sacrifice.
void evLeave(Game g, Obj x, bool died)
{
    if (g.quiet) return;
    ensureDerived(g);
    if (died) collectFrom(g, x, Event.dies, Subject.ofObj(x.oid), true);
    collectFrom(g, x, Event.leave, Subject.ofObj(x.oid), true);
    if (died && x.isUnit)
        foreach (l; g.field)
            collectFrom(g, l, l.ctrl == x.ctrl ? Event.allyDies : Event.enemyDies, Subject.ofObj(x.oid));
}

/// Player `p` lost Spire.
void evSpireLoss(Game g, Player p)
{
    if (g.quiet) return;
    ensureDerived(g);
    foreach (l; g.field)
        collectFrom(g, l, l.ctrl == p ? Event.spireLoss : Event.enemySpireLoss, Subject.ofPlayer(p));
}

/// Collect `mine` from Field objects controlled by `p` and `theirs` from the opponent's.
void evPlayerEvent(Game g, Player p, Event mine, Event theirs, Subject it)
{
    if (g.quiet) return;
    ensureDerived(g);
    foreach (l; g.field)
    {
        if (l.ctrl == p) collectFrom(g, l, mine, it);
        else if (theirs != mine) collectFrom(g, l, theirs, it);
    }
}

private long[4] triggerKey(Game g, in Pending p)
{
    return [p.ctrl == g.active ? 0 : 1, p.ts, p.src.oid, p.abilityIndex];
}

/// Push the collected triggers onto the Chain (13.3). Returns whether the pending list was non-empty.
bool pushTriggers(Game g)
{
    if (g.pending.length == 0) return false;
    auto list = g.pending;
    g.pending = null;
    list.sort!((a, b) => triggerKey(g, a) < triggerKey(g, b), SwapStrategy.stable);
    Entry[] made;
    foreach (ref p; list)
    {
        auto e = new Entry;
        e.kind = EntryKind.trigger;
        e.ctrl = p.ctrl;
        e.src = p.src;
        e.abilityIndex = p.abilityIndex;
        e.it = p.it;
        if (p.delayed !is null)
        {
            e.delayed = true;
            e.targets = p.delayed.targets.dup;
            e.specs = p.delayed.specs;
            e.delayedEffects = p.delayed.effects;
        }
        else
        {
            auto ab = p.src.card.abilities[p.abilityIndex - 1];
            if (ab.hasTargets)
            {
                e.specs = ab.targets;
                bool ok = true;
                foreach (spec; ab.targets)
                {
                    bool found;
                    foreach (cand; candidates(g, spec, p.ctrl, p.src, 0))
                    {
                        bool dup;
                        foreach (t; e.targets) if (t.kind == cand.kind && t.id == cand.id) dup = true;
                        if (dup) continue;
                        e.targets ~= cand;
                        found = true;
                        break;
                    }
                    if (!found) { ok = false; break; }
                }
                if (!ok)
                {
                    g.emit("TRIGGER-NO-TARGET", Game.r(p.ctrl), Game.r(p.src), p.abilityIndex);
                    continue;
                }
            }
        }
        e.cid = g.nextCid++;
        string line = "";
        foreach (t; e.targets) line ~= " " ~ g.render(t);
        emitTrigger(g, e, line);
        made ~= e;
    }
    foreach_reverse (e; made) g.chain ~= e;
    return true;
}

private void emitTrigger(Game g, Entry e, string targets)
{
    import std.conv : to;
    g.rawEvent("TRIGGER " ~ Game.r(e.ctrl) ~ " ~" ~ e.cid.to!string ~ " " ~ Game.r(e.src) ~ " "
        ~ e.abilityIndex.to!string ~ targets);
}

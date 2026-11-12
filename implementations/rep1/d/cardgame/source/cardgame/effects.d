/**
 * The effect interpreter: executes the effect forms of SPEC.md section 6.8.
 */
module cardgame.effects;

import std.algorithm : sort;
import std.conv : to;
import cardgame.chain : negateEntry;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.procs;
import cardgame.select;

/// Execute effects in written order.
void execEffects(Game g, const Effect[] es, ref Ctx c)
{
    foreach (e; es) execEffect(g, e, c);
}

private Target[] damageTargets(Game g, const DSel d, ref Ctx c)
{
    Target[] r;
    final switch (d.kind)
    {
    case DSel.Kind.player:
        foreach (p; selectPlayers(g, d.player, c)) r ~= Target.ofPlayer(p);
        break;
    case DSel.Kind.object:
        foreach (o; selectObjs(g, d.object, c)) r ~= Target.ofObj(o.oid);
        break;
    case DSel.Kind.target:
        if (c.ent !is null && d.n <= c.ent.targets.length)
        {
            auto t = c.ent.targets[d.n - 1];
            if (!t.removed && t.kind != Target.Kind.chain) r ~= t;
        }
        break;
    }
    r.sort!((a, b) => targetLess(g, a, b));
    return r;
}

private Obj[] fieldOnly(Obj[] os)
{
    Obj[] r;
    foreach (o; os) if (o.zone == Zone.field) r ~= o;
    return r;
}

private Record newRecord(Game g, RecKind k, ref Ctx c, Obj[] affected)
{
    auto r = new Record;
    r.eid = g.nextEid++;
    r.ts = g.takeTs();
    r.ctrl = c.ctrl;
    r.src = c.src;
    r.kind = k;
    foreach (o; affected) r.affected ~= o.oid;
    g.records ~= r;
    g.dirty = true;
    return r;
}

/// Execute one effect.
void execEffect(Game g, const Effect e, ref Ctx c)
{
    final switch (e.kind)
    {
    case Effect.Kind.damage:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (t; damageTargets(g, e.dsel, c)) dealDamage(g, c.src, t, n);
        break;
    }
    case Effect.Kind.destroy:
        foreach (o; selectObjs(g, e.sel, c)) destroyObj(g, o);
        break;
    case Effect.Kind.sacrifice:
        foreach (o; selectObjs(g, e.sel, c)) sacrificeObj(g, o);
        break;
    case Effect.Kind.exile:
        foreach (o; selectObjs(g, e.sel, c)) exileObj(g, o);
        break;
    case Effect.Kind.bounce:
        foreach (o; selectObjs(g, e.sel, c)) bounceObj(g, o);
        break;
    case Effect.Kind.draw:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c)) drawCards(g, p, n);
        break;
    }
    case Effect.Kind.discard:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c))
            for (long i = 0; i < n && g.pl[p].hand.length > 0; ++i) discardTop(g, p);
        break;
    }
    case Effect.Kind.mill:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c))
            for (long i = 0; i < n && !g.pl[p].vault.empty; ++i) millTop(g, p);
        break;
    }
    case Effect.Kind.spire:
    {
        immutable n = evalAmount(g, e.amt, c);
        foreach (p; selectPlayers(g, e.psel, c)) changeSpire(g, p, n);
        break;
    }
    case Effect.Kind.ember:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c)) gainEmber(g, p, n);
        break;
    }
    case Effect.Kind.cap:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c)) raiseCap(g, p, n);
        break;
    }
    case Effect.Kind.modify:
    case Effect.Kind.setbody:
    {
        immutable a = evalAmount(g, e.amt, c);
        immutable b = evalAmount(g, e.amt2, c);
        auto objs = fieldOnly(selectObjs(g, e.sel, c));
        immutable isMod = e.kind == Effect.Kind.modify;
        auto r = newRecord(g, isMod ? RecKind.modify : RecKind.setbody, c, objs);
        r.a = a; r.b = b;
        foreach (o; objs) g.emit(isMod ? "BUFF" : "SETBODY", Game.r(o), a, b);
        break;
    }
    case Effect.Kind.swapstats:
    {
        auto objs = fieldOnly(selectObjs(g, e.sel, c));
        newRecord(g, RecKind.swapstats, c, objs);
        foreach (o; objs) g.emit("SWAP", Game.r(o));
        break;
    }
    case Effect.Kind.grant:
    {
        auto objs = fieldOnly(selectObjs(g, e.sel, c));
        auto r = newRecord(g, RecKind.grant, c, objs);
        r.kw = e.kw;
        foreach (o; objs) g.emit("GRANT", Game.r(o), e.kw.render());
        break;
    }
    case Effect.Kind.strip:
    {
        auto objs = fieldOnly(selectObjs(g, e.sel, c));
        newRecord(g, RecKind.strip, c, objs);
        foreach (o; objs) g.emit("STRIP", Game.r(o));
        break;
    }
    case Effect.Kind.control:
    {
        auto objs = fieldOnly(selectObjs(g, e.sel, c));
        newRecord(g, RecKind.control, c, objs);
        foreach (o; objs)
        {
            o.since = g.turn;
            removeFromCombat(g, o);
        }
        foreach (o; objs) g.emit("CONTROL", Game.r(o), Game.r(c.ctrl));
        break;
    }
    case Effect.Kind.counters:
    {
        immutable n = evalAmount(g, e.amt, c);
        foreach (o; selectObjs(g, e.sel, c)) changeCounters(g, o, n);
        break;
    }
    case Effect.Kind.ready:
        foreach (o; selectObjs(g, e.sel, c)) setExhausted(g, o, false);
        break;
    case Effect.Kind.exhaust:
        foreach (o; selectObjs(g, e.sel, c)) setExhausted(g, o, true);
        break;
    case Effect.Kind.doom:
        foreach (o; selectObjs(g, e.sel, c)) doomObj(g, o);
        break;
    case Effect.Kind.ward:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (o; selectObjs(g, e.sel, c))
        {
            if (o.zone != Zone.field) continue;
            o.ward += cast(int) n;
            g.dirty = true;
            g.emit("WARD", Game.r(o), n, o.ward);
        }
        break;
    }
    case Effect.Kind.shield:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c))
        {
            g.pl[p].shield += n;
            g.emit("SHIELD", Game.r(p), n, g.pl[p].shield);
        }
        break;
    }
    case Effect.Kind.summon:
    case Effect.Kind.conjure:
    {
        immutable n = evalAmount(g, e.amt, c);
        if (n <= 0) break;
        foreach (p; selectPlayers(g, e.psel, c))
            for (long i = 0; i < n; ++i) createObject(g, e.cardId, p, e.kind == Effect.Kind.summon);
        break;
    }
    case Effect.Kind.reanimate:
        foreach (o; selectObjs(g, e.sel, c)) reanimateObj(g, o, c.ctrl);
        break;
    case Effect.Kind.recall:
        foreach (o; selectObjs(g, e.sel, c)) recallObj(g, o);
        break;
    case Effect.Kind.negate:
    {
        if (c.ent !is null && e.sel.n <= c.ent.targets.length)
        {
            auto t = c.ent.targets[e.sel.n - 1];
            if (t.kind == Target.Kind.chain && !t.removed)
            {
                auto ent = g.entryByCid(t.id);
                if (ent !is null) negateEntry(g, ent);
            }
        }
        break;
    }
    case Effect.Kind.dig:
        foreach (p; selectPlayers(g, e.psel, c)) digCards(g, p, e.digCount, e.digFilters, c);
        break;
    case Effect.Kind.delay:
    {
        auto d = new Delayed;
        d.ts = g.takeTs();
        d.ctrl = c.ctrl;
        d.when = e.when;
        d.src = c.src;
        if (c.ent !is null)
        {
            d.targets = c.ent.targets.dup;
            foreach (ref t; d.targets) t.removed = false;
            d.specs = c.ent.specs;
        }
        d.effects = cast(Effect[]) e.body_;
        g.delayed ~= d;
        g.emit("DELAY", Game.r(c.ctrl), whenNames[e.when]);
        break;
    }
    case Effect.Kind.if_:
        if (evalCond(g, e.cond, c)) execEffects(g, e.body_, c);
        else execEffects(g, e.elseBody, c);
        break;
    case Effect.Kind.each:
    {
        auto list = selectObjs(g, e.sel, c);
        Zone[] zones;
        foreach (o; list) zones ~= o.zone;
        auto saved = c.that;
        foreach (i, o; list)
        {
            if (o.zone != zones[i]) continue;
            c.that = o;
            execEffects(g, e.body_, c);
        }
        c.that = saved;
        break;
    }
    case Effect.Kind.repeat:
    {
        immutable n = evalAmount(g, e.amt, c);
        for (long i = 0; i < n; ++i) execEffects(g, e.body_, c);
        break;
    }
    case Effect.Kind.nothing: break;
    }
}

/**
 * The effect interpreter (SPEC 6.8): a tree-walking evaluator over the typed
 * effect trees produced by the database parser.
 */
module cardgame.effects;

import cardgame.actions;
import cardgame.cards;
import cardgame.eval;
import cardgame.game;

/// Render a keyword instance: its name, or `plating:N`.
string kwString(Kw k)
{
    import std.conv : to;

    if (k.kind == Keyword.plating)
        return "plating:" ~ k.value.to!string;
    return keywordName(k.kind);
}

/// Execute a list of effects in order.
void execEffects(Game g, Effect[] effs, ref Ctx c)
{
    foreach (e; effs)
    {
        if (g.over)
            return;
        execEffect(g, e, c);
    }
}

private Rec newRecord(Game g, RecKind kind, ref Ctx c, int[] affected)
{
    auto r = new Rec;
    r.eid = g.nextEid++;
    r.ts = g.takeTs();
    r.ctrl = c.ctrl;
    r.src = c.src;
    r.kind = kind;
    r.affected = affected;
    g.recs ~= r;
    g.touch();
    return r;
}

private int[] fieldObjs(Game g, Sel s, ref Ctx c)
{
    int[] all;
    selObjs(g, s, c, all);
    int[] r;
    foreach (o; all)
        if (g.onField(o))
            r ~= o;
    return r;
}

/// Execute one effect.
void execEffect(Game g, Effect e, ref Ctx c)
{
    final switch (e.kind)
    {
    case EffKind.damage:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            foreach (t; selTargets(g, e.sel, c))
                dealDamage(g, c.src, t, n);
            break;
        }
    case EffKind.destroy:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                destroyObj(g, o);
            break;
        }
    case EffKind.sacrifice:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                sacrificeObj(g, o);
            break;
        }
    case EffKind.exile:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                exileObj(g, o);
            break;
        }
    case EffKind.bounce:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                bounceObj(g, o);
            break;
        }
    case EffKind.draw:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    drawCards(g, p, n);
            break;
        }
    case EffKind.discard:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    for (long i = 0; i < n && g.hand[p].length; i++)
                        discardOne(g, p);
            break;
        }
    case EffKind.mill:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    for (long i = 0; i < n && g.vault[p].length; i++)
                        millOne(g, p);
            break;
        }
    case EffKind.spire:
        {
            immutable n = amtVal(g, e.a, c);
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    changeSpire(g, p, n);
            break;
        }
    case EffKind.ember:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    gainEmber(g, p, n);
            break;
        }
    case EffKind.cap:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    raiseCap(g, p, n);
            break;
        }
    case EffKind.shield:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                {
                    g.shield[p] += cast(int) n;
                    g.ev("SHIELD", Pl(p), n, g.shield[p]);
                }
            break;
        }
    case EffKind.modify:
    case EffKind.setbody:
        {
            immutable av = amtVal(g, e.a, c);
            immutable bv = amtVal(g, e.b, c);
            auto affected = fieldObjs(g, e.sel, c);
            auto r = newRecord(g, e.kind == EffKind.modify ? RecKind.modify : RecKind.setbody, c, affected);
            r.a = av;
            r.b = bv;
            foreach (o; affected)
                g.ev(e.kind == EffKind.modify ? "BUFF" : "SETBODY", O(o), av, bv);
            break;
        }
    case EffKind.swapstats:
        {
            auto affected = fieldObjs(g, e.sel, c);
            newRecord(g, RecKind.swapstats, c, affected);
            foreach (o; affected)
                g.ev("SWAP", O(o));
            break;
        }
    case EffKind.grant:
        {
            auto affected = fieldObjs(g, e.sel, c);
            auto r = newRecord(g, RecKind.grant, c, affected);
            r.kw = e.kw;
            foreach (o; affected)
                g.ev("GRANT", O(o), kwString(e.kw));
            break;
        }
    case EffKind.strip:
        {
            auto affected = fieldObjs(g, e.sel, c);
            newRecord(g, RecKind.strip, c, affected);
            foreach (o; affected)
                g.ev("STRIP", O(o));
            break;
        }
    case EffKind.control:
        {
            auto affected = fieldObjs(g, e.sel, c);
            newRecord(g, RecKind.control, c, affected);
            foreach (o; affected)
            {
                g.objs[o].since = g.turn;
                removeFromCombat(g, o);
            }
            foreach (o; affected)
                g.ev("CONTROL", O(o), Pl(c.ctrl));
            break;
        }
    case EffKind.counters:
        {
            immutable n = amtVal(g, e.a, c);
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                addCounters(g, o, n);
            break;
        }
    case EffKind.ready:
    case EffKind.exhaust:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                setExhausted(g, o, e.kind == EffKind.exhaust);
            break;
        }
    case EffKind.doom:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                doomObj(g, o);
            break;
        }
    case EffKind.ward:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                if (g.onField(o))
                {
                    g.objs[o].ward += cast(int) n;
                    g.ev("WARD", O(o), n, g.objs[o].ward);
                }
            break;
        }
    case EffKind.summon:
    case EffKind.conjure:
        {
            immutable n = amtVal(g, e.a, c);
            if (n <= 0)
                return;
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    for (long i = 0; i < n; i++)
                        createCard(g, e.cardIdx, p, e.kind == EffKind.summon, p);
            break;
        }
    case EffKind.reanimate:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                reanimateObj(g, o, c.ctrl);
            break;
        }
    case EffKind.recall:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            foreach (o; objs)
                recallObj(g, o);
            break;
        }
    case EffKind.negate:
        {
            if (c.entry !is null && e.sel.n >= 1 && e.sel.n <= c.entry.targets.length)
            {
                auto t = c.entry.targets[e.sel.n - 1];
                if (t.kind == 2 && !c.entry.removed[e.sel.n - 1])
                    negateEntry(g, t.id);
            }
            break;
        }
    case EffKind.dig:
        {
            immutable m = playerMask(g, e.sel, c);
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    digCards(g, p, e, c);
            break;
        }
    case EffKind.delay:
        {
            auto d = new Delayed;
            d.ts = g.takeTs();
            d.ctrl = c.ctrl;
            d.src = c.src;
            d.when = e.when;
            d.effects = e.body_;
            if (c.entry !is null)
            {
                d.targets = c.entry.targets.dup;
                d.specs = c.entry.specs;
            }
            g.delayed ~= d;
            g.ev("DELAY", Pl(c.ctrl), delayName(e.when));
            break;
        }
    case EffKind.ifElse:
        if (condVal(g, e.cond, c))
            execEffects(g, e.body_, c);
        else
            execEffects(g, e.elseBody, c);
        break;
    case EffKind.each:
        {
            int[] objs;
            selObjs(g, e.sel, c, objs);
            ZoneKind[] zones;
            foreach (o; objs)
                zones ~= g.objs[o].zone;
            foreach (i, o; objs)
            {
                if (g.objs[o].zone != zones[i])
                    continue;
                c.thatStack ~= o;
                execEffects(g, e.body_, c);
                c.thatStack = c.thatStack[0 .. $ - 1];
            }
            break;
        }
    case EffKind.repeat:
        {
            immutable n = amtVal(g, e.a, c);
            for (long i = 0; i < n; i++)
                execEffects(g, e.body_, c);
            break;
        }
    case EffKind.nothing:
        break;
    }
}

/// `dig` for one player (SPEC 17.21).
private void digCards(Game g, int p, Effect e, ref Ctx c)
{
    long take = e.k < 0 ? 0 : e.k;
    if (take > g.vault[p].length)
        take = g.vault[p].length;
    int[] look = g.vault[p][0 .. cast(size_t) take].dup;
    g.vault[p] = g.vault[p][cast(size_t) take .. $];
    g.touchDep(Dep.zones);
    int found = -1;
    foreach (i, o; look)
        if (filtersMatch(g, e.filters, o, c))
        {
            found = cast(int) i;
            break;
        }
    if (found >= 0)
    {
        immutable o = look[found];
        look = look[0 .. found] ~ look[found + 1 .. $];
        putInZone(g, o, ZoneKind.hand);
        g.ev("DIG", Pl(p), O(o), g.cardOf(o).id);
    }
    else
        g.ev("DIG-MISS", Pl(p));
    foreach (o; look)
    {
        g.vault[p] ~= o;
        g.ev("BOTTOM", Pl(p), O(o), g.cardOf(o).id);
    }
    g.touchDep(Dep.zones);
}

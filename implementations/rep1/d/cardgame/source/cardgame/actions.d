/**
 * State-changing procedures of SPEC section 17 and trigger collection (13).
 *
 * Every procedure here is atomic: it neither runs state checks nor pushes
 * triggers; it only collects them into `Game.pending`.
 */
module cardgame.actions;

import std.algorithm : min, max;

import cardgame.cards;
import cardgame.derive;
import cardgame.game;

// ------------------------------------------------------------------ triggers

/// Queue one triggered ability.
void addPending(Game g, int oid, int abil, int ctrl, int ts, Subject it)
{
    Pending p;
    p.side = ctrl == g.active ? 0 : 1;
    p.ts = ts;
    p.oid = oid;
    p.abil = abil;
    p.ctrl = ctrl;
    p.it = it;
    p.seq = g.pendingSeq++;
    g.pending ~= p;
}

/// Collect the `ev` abilities of the single object `oid`.
void collectSelf(Game g, int oid, Event ev, Subject it, bool ignoreStrip = false,
        int ctrlOverride = -1)
{
    auto card = g.cardOf(oid);
    if (!(card.eventMask & (1u << ev)))
        return;
    if (!ignoreStrip)
    {
        if (!g.onField(oid) || g.isStripped(oid))
            return;
    }
    immutable ctrl = ctrlOverride >= 0 ? ctrlOverride : g.ctl(oid);
    foreach (i, ab; card.abilities)
        if (ab.kind == AbilKind.on && ab.event == ev)
            addPending(g, oid, cast(int) i + 1, ctrl, g.objs[oid].ts, it);
}

/**
 * Collect an event from every listening object on the Field.
 *
 * `who` is the player argument (the player who drew, played, lost Spire, or the
 * controller of a unit that died); `subject` is the object that arrived or died.
 */
void collectScan(Game g, Event ev, Subject it, int who = -1, int subject = 0)
{
    foreach (x; g.field)
    {
        auto card = g.cardOf(x);
        if (!(card.eventMask & (1u << ev)))
            continue;
        if (g.isStripped(x))
            continue;
        immutable c = g.ctl(x);
        bool ok;
        final switch (ev)
        {
        case Event.allyArrive:
            ok = x != subject && c == g.ctl(subject);
            break;
        case Event.enemyArrive:
            ok = c != g.ctl(subject);
            break;
        case Event.allyDies:
            ok = x != subject && c == who;
            break;
        case Event.enemyDies:
            ok = c != who;
            break;
        case Event.turnStart:
        case Event.turnEnd:
            ok = true;
            break;
        case Event.yourTurnStart:
        case Event.yourTurnEnd:
            ok = c == g.active;
            break;
        case Event.youPlayRite:
        case Event.youDraw:
        case Event.spireLoss:
            ok = c == who;
            break;
        case Event.enemyPlaysRite:
        case Event.enemySpireLoss:
            ok = c != who;
            break;
        case Event.arrive:
        case Event.leave:
        case Event.dies:
        case Event.attacks:
        case Event.blocks:
        case Event.blocked:
        case Event.unblocked:
        case Event.damaged:
        case Event.dealsDamage:
        case Event.endOfCombat:
            ok = false;
            break;
        }
        if (!ok)
            continue;
        foreach (i, ab; card.abilities)
            if (ab.kind == AbilKind.on && ab.event == ev)
                addPending(g, x, cast(int) i + 1, c, g.objs[x].ts, it);
    }
}

// --------------------------------------------------------------- zone moves

/// Remove an object from a non-Field zone list.
void detachFromZone(Game g, int oid)
{
    auto o = &g.objs[oid];
    final switch (o.zone)
    {
    case ZoneKind.vault:
        removeValue(g.vault[o.owner], oid);
        break;
    case ZoneKind.hand:
        removeValue(g.hand[o.owner], oid);
        break;
    case ZoneKind.ash:
        removeValue(g.ash[o.owner], oid);
        break;
    case ZoneKind.rift:
        removeValue(g.rift[o.owner], oid);
        break;
    case ZoneKind.field:
    case ZoneKind.chain:
    case ZoneKind.none:
        break;
    }
    o.zone = ZoneKind.none;
    g.touchDep(Dep.zones);
}

/// Take a unit out of combat (SPEC 7.5 "Removal from combat").
void removeFromCombat(Game g, int oid)
{
    g.touchDep(Dep.combat);
    auto o = &g.objs[oid];
    if (o.blocking)
    {
        removeValue(g.objs[o.blockTarget].blockers, oid);
        o.blocking = false;
        o.blockTarget = 0;
    }
    if (o.attacking)
    {
        foreach (b; o.blockers)
        {
            g.objs[b].blocking = false;
            g.objs[b].blockTarget = 0;
        }
        o.blockers.length = 0;
        o.attacking = false;
        o.blocked = false;
    }
}

/// Take an object off the Field, discarding its Field state and aura records.
/// The caller sets the new zone.
void leaveField(Game g, int oid)
{
    ensureDerived(g);
    auto o = &g.objs[oid];
    o.ctrl = o.cur;
    removeFromCombat(g, oid);
    removeValue(g.field, oid);
    size_t w = 0;
    foreach (r; g.recs)
        if (!(r.aura && r.src == oid))
            g.recs[w++] = r;
    g.recs = g.recs[0 .. w];
    o.exhausted = false;
    o.doomed = false;
    o.tenUsed = false;
    o.wounds = 0;
    o.counters = 0;
    o.ward = 0;
    o.since = 0;
    o.onceMask = 0;
    o.blockers.length = 0;
    o.zone = ZoneKind.none;
    g.touch();
}

/// Put an object on the Field without events: timestamp, state reset, aura records.
void placeOnField(Game g, int oid, int ctrl, int since)
{
    auto o = &g.objs[oid];
    o.zone = ZoneKind.field;
    o.ts = g.takeTs();
    o.ctrl = cast(ubyte) ctrl;
    o.cur = cast(ubyte) ctrl;
    o.since = since;
    o.exhausted = false;
    o.doomed = false;
    o.tenUsed = false;
    o.wounds = 0;
    o.counters = 0;
    o.ward = 0;
    o.onceMask = 0;
    o.attacking = o.blocking = o.blocked = false;
    o.blockTarget = 0;
    o.blockers.length = 0;
    g.field ~= oid;
    foreach (ab; g.cardOf(oid).abilities)
        if (ab.kind == AbilKind.aura)
        {
            auto r = new Rec;
            r.eid = g.nextEid++;
            r.ts = g.takeTs();
            r.src = oid;
            r.aura = true;
            r.ability = ab;
            r.ctrl = ctrl;
            g.recs ~= r;
        }
    g.touch();
}

/// Enter the Field (SPEC 17.17): place, emit `ARRIVE`, collect arrival triggers.
void enterField(Game g, int oid, int ctrl)
{
    placeOnField(g, oid, ctrl, g.turn);
    g.ev("ARRIVE", O(oid), g.cardOf(oid).id);
    collectSelf(g, oid, Event.arrive, Subject.obj(oid));
    if (g.cardOf(oid).type == CardType.unit)
    {
        collectScan(g, Event.allyArrive, Subject.obj(oid), -1, oid);
        collectScan(g, Event.enemyArrive, Subject.obj(oid), -1, oid);
    }
}

/// Append to a zone list of the owner.
void putInZone(Game g, int oid, ZoneKind z)
{
    auto o = &g.objs[oid];
    o.zone = z;
    final switch (z)
    {
    case ZoneKind.vault:
        g.vault[o.owner] ~= oid;
        break;
    case ZoneKind.hand:
        g.hand[o.owner] ~= oid;
        break;
    case ZoneKind.ash:
        g.ash[o.owner] ~= oid;
        break;
    case ZoneKind.rift:
        g.rift[o.owner] ~= oid;
        break;
    case ZoneKind.field:
    case ZoneKind.chain:
    case ZoneKind.none:
        break;
    }
    g.touchDep(Dep.zones);
}

private void collectLeaving(Game g, int oid, int ctrl, bool died)
{
    ensureDerived(g);
    if (died)
        collectSelf(g, oid, Event.dies, Subject.obj(oid), true, ctrl);
    collectSelf(g, oid, Event.leave, Subject.obj(oid), true, ctrl);
    if (died && g.cardOf(oid).type == CardType.unit)
    {
        collectScan(g, Event.allyDies, Subject.obj(oid), ctrl, oid);
        collectScan(g, Event.enemyDies, Subject.obj(oid), ctrl, oid);
    }
}

// -------------------------------------------------------- destroy and friends

/// Destroy an object on the Field (SPEC 17.3), honouring `tenacity`.
void destroyObj(Game g, int oid)
{
    if (!g.onField(oid))
        return;
    auto o = &g.objs[oid];
    if (!o.tenUsed && g.hasKw(oid, Keyword.tenacity))
    {
        o.tenUsed = true;
        o.wounds = 0;
        o.doomed = false;
        g.touchDep(Dep.wounds);
        g.ev("TENACITY", O(oid));
        return;
    }
    removeAndDie(g, oid, "DESTROY");
}

/// Sacrifice an object on the Field (SPEC 17.4).
void sacrificeObj(Game g, int oid)
{
    if (!g.onField(oid))
        return;
    removeAndDie(g, oid, "SACRIFICE");
}

private void removeAndDie(Game g, int oid, string evName)
{
    immutable ctrl = g.ctl(oid);
    leaveField(g, oid);
    putInZone(g, oid, ZoneKind.ash);
    g.ev(evName, O(oid), g.cardOf(oid).id);
    collectLeaving(g, oid, ctrl, true);
}

private immutable string[7] zoneNames = ["none", "vault", "hand", "field", "ash", "rift", "chain"];

/// Exile an object from any zone (SPEC 17.5).
void exileObj(Game g, int oid)
{
    auto o = &g.objs[oid];
    immutable z = o.zone;
    if (z == ZoneKind.none || z == ZoneKind.chain)
        return;
    int ctrl = 0;
    if (z == ZoneKind.field)
    {
        ctrl = g.ctl(oid);
        leaveField(g, oid);
    }
    else
        detachFromZone(g, oid);
    putInZone(g, oid, ZoneKind.rift);
    g.ev("EXILE", O(oid), g.cardOf(oid).id, zoneNames[z]);
    if (z == ZoneKind.field)
        collectLeaving(g, oid, ctrl, false);
}

/// Return a Field object to its owner's hand (SPEC 17.6).
void bounceObj(Game g, int oid)
{
    if (!g.onField(oid))
        return;
    immutable ctrl = g.ctl(oid);
    leaveField(g, oid);
    putInZone(g, oid, ZoneKind.hand);
    g.ev("BOUNCE", O(oid), g.cardOf(oid).id);
    collectLeaving(g, oid, ctrl, false);
}

// ------------------------------------------------------------ player changes

/// Change a player's Spire by a signed amount (SPEC 17.10).
void changeSpire(Game g, int p, long amt)
{
    if (amt == 0)
        return;
    g.spire[p] += cast(int) amt;
    g.touchDep(Dep.spire);
    g.ev("SPIRE", Pl(p), Sg(amt), g.spire[p]);
    if (amt < 0)
    {
        collectScan(g, Event.spireLoss, Subject.player(p), p);
        collectScan(g, Event.enemySpireLoss, Subject.player(p), p);
    }
}

/// Gain Ember (SPEC 17.11).
void gainEmber(Game g, int p, long n)
{
    if (n <= 0)
        return;
    g.ember[p] += cast(int) n;
    g.touchDep(Dep.ember);
    g.ev("EMBERGAIN", Pl(p), n, g.ember[p]);
}

/// Raise the Ember cap (SPEC 17.12).
void raiseCap(Game g, int p, long n)
{
    if (n <= 0)
        return;
    g.cap[p] = cast(int) min(cast(long) g.cap[p] + n, cast(long) g.cfg.maxCap);
    g.ev("CAP", Pl(p), n, g.cap[p]);
}

/// Record a loss for a player unless one is already recorded.
void recordLoss(Game g, int p, Loss reason)
{
    if (g.loss[p] == Loss.none)
        g.loss[p] = reason;
}

/// Draw one card; false when the Vault was empty (SPEC 17.7).
bool drawOne(Game g, int p, bool triggers)
{
    if (g.vault[p].length == 0)
    {
        g.ev("DRAW-EMPTY", Pl(p));
        recordLoss(g, p, Loss.vault);
        return false;
    }
    immutable oid = g.vault[p][0];
    g.vault[p] = g.vault[p][1 .. $];
    g.objs[oid].zone = ZoneKind.hand;
    g.hand[p] ~= oid;
    g.touchDep(Dep.zones);
    g.ev("DRAW", Pl(p), O(oid), g.cardOf(oid).id);
    if (triggers)
        collectScan(g, Event.youDraw, Subject.obj(oid), p);
    return true;
}

/// Draw up to `n` cards, stopping at the first empty Vault.
void drawCards(Game g, int p, long n, bool triggers = true)
{
    for (long i = 0; i < n; i++)
        if (!drawOne(g, p, triggers))
            break;
}

/// Discard the first card of a hand (SPEC 17.8).
void discardOne(Game g, int p)
{
    if (g.hand[p].length == 0)
        return;
    immutable oid = g.hand[p][0];
    g.hand[p] = g.hand[p][1 .. $];
    putInZone(g, oid, ZoneKind.ash);
    g.ev("DISCARD", Pl(p), O(oid), g.cardOf(oid).id);
}

/// Mill the top Vault card (SPEC 17.9).
void millOne(Game g, int p)
{
    if (g.vault[p].length == 0)
        return;
    immutable oid = g.vault[p][0];
    g.vault[p] = g.vault[p][1 .. $];
    putInZone(g, oid, ZoneKind.ash);
    g.ev("MILL", Pl(p), O(oid), g.cardOf(oid).id);
}

// ------------------------------------------------------------ object changes

/// Add (or remove) charge counters (SPEC 17.14).
void addCounters(Game g, int oid, long n)
{
    if (!g.onField(oid))
        return;
    auto o = &g.objs[oid];
    immutable old = o.counters;
    long nw = old + n;
    if (nw < 0)
        nw = 0;
    if (nw == old)
        return;
    o.counters = cast(int) nw;
    g.touch();
    g.ev("COUNTERS", O(oid), Sg(nw - old), nw);
}

/// Ready or exhaust an object on the Field (SPEC 17.15).
void setExhausted(Game g, int oid, bool exhausted)
{
    if (!g.onField(oid))
        return;
    auto o = &g.objs[oid];
    if (o.exhausted == exhausted)
        return;
    o.exhausted = exhausted;
    g.touchDep(Dep.ready);
    g.ev(exhausted ? "EXHAUST" : "READY", O(oid));
}

/// Mark a Field unit Doomed (SPEC 17.16).
void doomObj(Game g, int oid)
{
    if (!g.onField(oid) || g.cardOf(oid).type != CardType.unit)
        return;
    g.objs[oid].doomed = true;
    // (not observable by auras)
    g.ev("DOOM", O(oid));
}

/// Deal damage from the object `src` to a target (SPEC 17.1, 15.2).
void dealDamage(Game g, int src, Target t, long n)
{
    if (n <= 0)
        return;
    if (t.kind == 1)
    {
        if (!g.onField(t.id) || g.cardOf(t.id).type != CardType.unit)
            return;
    }
    long m = n;
    if (t.kind == 1)
    {
        m -= g.plating(t.id);
        if (m < 0)
            m = 0;
        immutable u = min(cast(long) g.objs[t.id].ward, m);
        g.objs[t.id].ward -= cast(int) u;
        m -= u;
    }
    else
    {
        immutable u = min(cast(long) g.shield[t.id], m);
        g.shield[t.id] -= cast(int) u;
        m -= u;
    }
    if (n - m > 0)
    {
        // (not observable by auras)
        g.ev("PREVENT", t, n - m);
    }
    if (m == 0)
        return;
    g.ev("DAMAGE", O(src), t, m);
    if (t.kind == 1)
    {
        g.objs[t.id].wounds += cast(int) m;
        g.touchDep(Dep.wounds);
    }
    else
        changeSpire(g, t.id, -m);
    immutable srcUnit = g.onField(src) && g.cardOf(src).type == CardType.unit;
    if (t.kind == 1 && srcUnit && g.hasKw(src, Keyword.venom))
    {
        g.objs[t.id].doomed = true;
        // (not observable by auras)
        g.ev("DOOM", O(t.id));
    }
    if (srcUnit && g.hasKw(src, Keyword.siphon))
    {
        immutable c = g.ctl(src);
        g.spire[c] += cast(int) m;
        g.touchDep(Dep.spire);
        g.ev("SPIRE", Pl(c), Sg(m), g.spire[c]);
    }
    if (t.kind == 1 && g.onField(t.id))
        collectSelf(g, t.id, Event.damaged, Subject.obj(src));
    if (g.onField(src))
        collectSelf(g, src, Event.dealsDamage,
                t.kind == 1 ? Subject.obj(t.id) : Subject.player(t.id));
}

/// Create a card instance for `owner` in the hand or on the Field (SPEC 17.17).
void createCard(Game g, int cardIdx, int owner, bool toField, int fieldCtrl)
{
    immutable oid = g.newObject(cardIdx, owner);
    g.ev("CREATE", O(oid), g.db.cards[cardIdx].id, toField ? "field" : "hand");
    if (toField)
        enterField(g, oid, fieldCtrl);
    else
        putInZone(g, oid, ZoneKind.hand);
}

/// Reanimate an Ash unit under `ctrl` (SPEC 17.18).
void reanimateObj(Game g, int oid, int ctrl)
{
    if (g.objs[oid].zone != ZoneKind.ash || g.cardOf(oid).type != CardType.unit)
        return;
    detachFromZone(g, oid);
    enterField(g, oid, ctrl);
}

/// Return an Ash card to its owner's hand (SPEC 17.19).
void recallObj(Game g, int oid)
{
    if (g.objs[oid].zone != ZoneKind.ash)
        return;
    detachFromZone(g, oid);
    putInZone(g, oid, ZoneKind.hand);
    g.ev("RECALL", O(oid), g.cardOf(oid).id);
}

/// Remove a Chain entry (SPEC 17.20).
void negateEntry(Game g, int cid)
{
    foreach (i, e; g.chain)
        if (e.cid == cid)
        {
            g.chain = g.chain[0 .. i] ~ g.chain[i + 1 .. $];
            g.ev("NEGATE", Q(cid));
            if (e.kind == EntryKind.rite || e.kind == EntryKind.unit || e.kind == EntryKind.relic)
            {
                putInZone(g, e.src, ZoneKind.ash);
                g.ev("SPENT", O(e.src), g.cardOf(e.src).id);
            }
            return;
        }
}

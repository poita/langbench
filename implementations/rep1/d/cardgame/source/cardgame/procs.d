/**
 * The atomic state-change procedures of SPEC.md section 17 (damage,
 * destruction, drawing, entering the Field, ...), with their events and
 * trigger collection. None of them runs a state check.
 */
module cardgame.procs;

import std.algorithm : min, max;
import std.conv : to;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.select;
import cardgame.triggers;

/// Keep combat status consistent when `o` leaves the Field or loses control (7.5).
void removeFromCombat(Game g, Obj o)
{
    if (o.blocking && o.blockedAttacker !is null)
    {
        auto a = o.blockedAttacker;
        size_t j = 0;
        foreach (b; a.blockers) if (b !is o) a.blockers[j++] = b;
        a.blockers.length = j;
    }
    if (o.attacking)
        foreach (b; o.blockers)
        {
            b.blocking = false;
            b.blockedAttacker = null;
        }
    o.attacking = false;
    o.blocking = false;
    o.blockedFlag = false;
    o.blockers = null;
    o.blockedAttacker = null;
    g.dirty = true;
}

/// Remove `o` from the Field into `dest` (or nowhere), discarding Field state.
void leaveField(Game g, Obj o, Zone dest)
{
    ensureDerived(g);
    removeFromCombat(g, o);
    removeAuraRecords(g, o);
    g.unplace(o);
    o.exhausted = false;
    o.wounds = 0;
    o.counters = 0;
    o.ward = 0;
    o.doomed = false;
    o.tenacityUsed = false;
    o.usedOnce = null;
    if (dest != Zone.none) g.place(o, dest);
}

/// Put `o` on the Field under `ctrl` (17.17 steps 1-3), without events.
void placeOnField(Game g, Obj o, Player ctrl)
{
    g.unplace(o);
    o.baseCtrl = ctrl;
    o.ctrl = ctrl;
    o.ts = g.takeTs();
    o.since = g.turn;
    o.exhausted = false;
    o.wounds = 0;
    o.counters = 0;
    o.ward = 0;
    o.doomed = false;
    o.tenacityUsed = false;
    o.usedOnce = null;
    o.attacking = o.blocking = o.blockedFlag = false;
    o.blockers = null;
    o.blockedAttacker = null;
    g.place(o, Zone.field);
    createAuraRecords(g, o);
}

/// Entering the Field as in 17.17.
void enterField(Game g, Obj o, Player ctrl)
{
    placeOnField(g, o, ctrl);
    g.emit("ARRIVE", Game.r(o), o.card.id);
    evArrive(g, o);
}

/// Create a new object of `cardId` for `p` in the hand or on the Field (17.17).
void createObject(Game g, string cardId, Player p, bool toField)
{
    auto o = g.createObj(g.db.find(cardId), p);
    g.emit("CREATE", Game.r(o), cardId, toField ? "field" : "hand");
    if (toField) enterField(g, o, p);
    else g.place(o, Zone.hand);
}

// ------------------------------------------------------------------ damage

/// Deal `n` damage from `s` to `t` (17.1 with 15.2).
void dealDamage(Game g, Obj s, Target t, long n)
{
    if (n <= 0) return;
    ensureDerived(g);
    Obj to = t.kind == Target.Kind.obj ? g.obj(t.id) : null;
    if (to !is null && (to.zone != Zone.field || !to.isUnit)) return;
    long m = n, prevented = 0;
    if (to !is null)
    {
        immutable red = min(max(cast(long) to.platingSum, 0L), m);
        m -= red; prevented += red;
        immutable u = min(cast(long) to.ward, m);
        to.ward -= cast(int) u; m -= u; prevented += u;
        g.dirty = true;
    }
    else
    {
        auto p = cast(Player) t.id;
        immutable u = min(g.pl[p].shield, m);
        g.pl[p].shield -= u; m -= u; prevented += u;
    }
    if (prevented > 0) g.emit("PREVENT", g.render(t), prevented);
    if (m == 0) return;
    g.emit("DAMAGE", Game.r(s), g.render(t), m);
    if (to !is null)
    {
        to.wounds += cast(int) m;
        g.dirty = true;
    }
    else
    {
        auto p = cast(Player) t.id;
        g.pl[p].spire -= m;
        g.dirty = true;
        g.emit("SPIRE", Game.r(p), Game.signed(-m), g.pl[p].spire);
        evSpireLoss(g, p);
    }
    ensureDerived(g);
    immutable srcOnField = s.zone == Zone.field && s.isUnit;
    if (to !is null && srcOnField && s.has(Kw.venom))
    {
        to.doomed = true;
        g.dirty = true;
        g.emit("DOOM", Game.r(to));
    }
    if (srcOnField && s.has(Kw.siphon))
    {
        auto c = s.ctrl;
        g.pl[c].spire += m;
        g.dirty = true;
        g.emit("SPIRE", Game.r(c), Game.signed(m), g.pl[c].spire);
    }
    if (to !is null) collectFrom(g, to, Event.damaged, Subject.ofObj(s.oid));
    if (s.zone == Zone.field)
        collectFrom(g, s, Event.dealsDamage,
            t.kind == Target.Kind.obj ? Subject.ofObj(t.id) : Subject.ofPlayer(cast(Player) t.id));
}

// ------------------------------------------------------------------ removal

/// Destroy `o` (17.3), applying `tenacity` first.
void destroyObj(Game g, Obj o)
{
    if (o.zone != Zone.field) return;
    ensureDerived(g);
    if (o.has(Kw.tenacity) && !o.tenacityUsed)
    {
        o.tenacityUsed = true;
        o.wounds = 0;
        o.doomed = false;
        g.dirty = true;
        g.emit("TENACITY", Game.r(o));
        return;
    }
    leaveField(g, o, Zone.ash);
    g.emit("DESTROY", Game.r(o), o.card.id);
    evLeave(g, o, true);
}

/// Sacrifice `o` (17.4).
void sacrificeObj(Game g, Obj o)
{
    if (o.zone != Zone.field) return;
    leaveField(g, o, Zone.ash);
    g.emit("SACRIFICE", Game.r(o), o.card.id);
    evLeave(g, o, true);
}

/// Exile `o` from wherever it is (17.5).
void exileObj(Game g, Obj o)
{
    immutable z = o.zone;
    if (z == Zone.none || z == Zone.chain) return;
    if (z == Zone.field)
    {
        leaveField(g, o, Zone.rift);
        g.emit("EXILE", Game.r(o), o.card.id, zoneName(z));
        evLeave(g, o, false);
    }
    else
    {
        g.move(o, Zone.rift);
        g.emit("EXILE", Game.r(o), o.card.id, zoneName(z));
    }
}

/// Bounce a Field object to its owner's hand (17.6).
void bounceObj(Game g, Obj o)
{
    if (o.zone != Zone.field) return;
    leaveField(g, o, Zone.hand);
    g.emit("BOUNCE", Game.r(o), o.card.id);
    evLeave(g, o, false);
}

/// Reanimate an Ash unit under `ctrl` (17.18).
void reanimateObj(Game g, Obj o, Player ctrl)
{
    if (o.zone != Zone.ash || !o.isUnit) return;
    enterField(g, o, ctrl);
}

/// Recall an Ash card to its owner's hand (17.19).
void recallObj(Game g, Obj o)
{
    if (o.zone != Zone.ash) return;
    g.move(o, Zone.hand);
    g.emit("RECALL", Game.r(o), o.card.id);
}

// ------------------------------------------------------------------ cards moving

/// Make `p` draw one card; false when the Vault was empty (17.7).
bool drawOne(Game g, Player p)
{
    auto pl = g.pl[p];
    if (pl.vault.empty)
    {
        g.emit("DRAW-EMPTY", Game.r(p));
        if (g.loss[p] is null) g.loss[p] = "vault";
        return false;
    }
    auto o = pl.vault.front;
    pl.vault.popFront();
    o.zone = Zone.none;
    g.place(o, Zone.hand);
    g.emit("DRAW", Game.r(p), Game.r(o), o.card.id);
    if (!g.quiet)
    {
        ensureDerived(g);
        foreach (l; g.field)
            if (l.ctrl == p) collectFrom(g, l, Event.youDraw, Subject.ofObj(o.oid));
    }
    return true;
}

/// Make `p` draw `n` cards, stopping at an empty Vault.
void drawCards(Game g, Player p, long n)
{
    for (long i = 0; i < n; ++i)
        if (!drawOne(g, p)) break;
}

/// Discard the first card of `p`'s hand (17.8).
void discardTop(Game g, Player p)
{
    auto h = g.pl[p].hand;
    if (h.length == 0) return;
    auto o = h[0];
    g.move(o, Zone.ash);
    g.emit("DISCARD", Game.r(p), Game.r(o), o.card.id);
}

/// Mill the top card of `p`'s Vault (17.9).
void millTop(Game g, Player p)
{
    auto pl = g.pl[p];
    if (pl.vault.empty) return;
    auto o = pl.vault.front;
    pl.vault.popFront();
    o.zone = Zone.none;
    g.place(o, Zone.ash);
    g.emit("MILL", Game.r(p), Game.r(o), o.card.id);
}

/// Change Spire by a signed amount (17.10).
void changeSpire(Game g, Player p, long n)
{
    if (n == 0) return;
    g.pl[p].spire += n;
    g.dirty = true;
    g.emit("SPIRE", Game.r(p), Game.signed(n), g.pl[p].spire);
    if (n < 0) evSpireLoss(g, p);
}

/// Gain Ember (17.11).
void gainEmber(Game g, Player p, long n)
{
    if (n <= 0) return;
    g.pl[p].ember += n;
    g.dirty = true;
    g.emit("EMBERGAIN", Game.r(p), n, g.pl[p].ember);
}

/// Raise the Ember cap (17.12).
void raiseCap(Game g, Player p, long n)
{
    if (n <= 0) return;
    g.pl[p].cap = min(g.pl[p].cap + n, cast(long) g.cfg.maxCap);
    g.emit("CAP", Game.r(p), n, g.pl[p].cap);
}

/// Add (or remove) charge counters (17.14).
void changeCounters(Game g, Obj o, long delta)
{
    if (o.zone != Zone.field) return;
    immutable old = o.counters;
    long nv = old + delta;
    if (nv < 0) nv = 0;
    if (nv > int.max) nv = int.max;
    if (nv == old) return;
    o.counters = cast(int) nv;
    g.dirty = true;
    g.emit("COUNTERS", Game.r(o), Game.signed(nv - old), nv);
}

/// Ready or exhaust a Field object (17.15).
void setExhausted(Game g, Obj o, bool exhausted)
{
    if (o.zone != Zone.field || o.exhausted == exhausted) return;
    o.exhausted = exhausted;
    g.dirty = true;
    g.emit(exhausted ? "EXHAUST" : "READY", Game.r(o));
}

/// Mark a Field unit Doomed (17.16).
void doomObj(Game g, Obj o)
{
    if (o.zone != Zone.field || !o.isUnit) return;
    o.doomed = true;
    g.dirty = true;
    g.emit("DOOM", Game.r(o));
}

/// Look at the top `k` cards and take the first match (17.21).
void digCards(Game g, Player p, long k, const Filter[] filters, ref Ctx c)
{
    auto pl = g.pl[p];
    Obj[] look;
    for (long i = 0; i < k && !pl.vault.empty; ++i)
    {
        look ~= pl.vault.front;
        pl.vault.popFront();
    }
    foreach (o; look) o.zone = Zone.none;
    g.dirty = true;
    long found = -1;
    foreach (i, o; look)
        if (matchAll(g, o, filters, c)) { found = cast(long) i; break; }
    if (found >= 0)
    {
        auto o = look[cast(size_t) found];
        g.place(o, Zone.hand);
        g.emit("DIG", Game.r(p), Game.r(o), o.card.id);
        look = look[0 .. cast(size_t) found] ~ look[cast(size_t) found + 1 .. $];
    }
    else g.emit("DIG-MISS", Game.r(p));
    foreach (o; look)
    {
        g.place(o, Zone.vault);
        g.emit("BOTTOM", Game.r(p), Game.r(o), o.card.id);
    }
}

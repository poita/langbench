/**
 * Combat: attack and block legality, declaration, and combat damage
 * (SPEC.md section 19).
 */
module cardgame.combat;

import std.algorithm : sort, max, min;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.procs;
import cardgame.select;
import cardgame.triggers;

/// 19.2: can `u` be declared as an attacker?
bool canAttack(Game g, Obj u)
{
    if (u is null || u.zone != Zone.field || !u.isUnit) return false;
    ensureDerived(g);
    return u.ctrl == g.active && !u.exhausted
        && (!isSettling(g, u) || u.has(Kw.vanguard)) && !u.has(Kw.shackled);
}

/// 19.4: can `b` block attacker `a`?
bool canBlock(Game g, Obj b, Obj a)
{
    if (b is null || a is null || b.zone != Zone.field || !b.isUnit) return false;
    ensureDerived(g);
    if (b.ctrl != opponent(g.active) || b.exhausted || b.has(Kw.siegework)) return false;
    if (a.zone != Zone.field || !a.attacking || !a.isUnit) return false;
    if (a.has(Kw.ghostwalk) && !(b.has(Kw.ghostwalk) || b.has(Kw.skyhook))) return false;
    return true;
}

/// Validate an `ATTACK`; returns the error kind or null.
string checkAttack(Game g, in ulong[] oids, out Obj[] list)
{
    foreach (i, a; oids)
        foreach (j; 0 .. i)
            if (oids[j] == a) return "duplicate-attacker";
    foreach (a; oids)
    {
        auto o = a > int.max ? null : g.obj(cast(long) a);
        if (!canAttack(g, o)) return "illegal-attacker";
        list ~= o;
    }
    foreach (o; g.field)
    {
        if (!o.has(Kw.relentless) || !canAttack(g, o)) continue;
        bool in_;
        foreach (x; list) if (x is o) in_ = true;
        if (!in_) return "missing-required-attacker";
    }
    return null;
}

/// Validate a `BLOCK`; returns the error kind or null.
string checkBlock(Game g, in ulong[] blockerIds, in ulong[] attackerIds, out Obj[] bs, out Obj[] as_)
{
    foreach (i, b; blockerIds)
        foreach (j; 0 .. i)
            if (blockerIds[j] == b) return "duplicate-blocker";
    foreach (i, bid; blockerIds)
    {
        auto b = bid > int.max ? null : g.obj(cast(long) bid);
        auto a = attackerIds[i] > int.max ? null : g.obj(cast(long) attackerIds[i]);
        if (!canBlock(g, b, a)) return "illegal-blocker";
        bs ~= b;
        as_ ~= a;
    }
    // provoke
    foreach (a; g.field)
    {
        if (!a.attacking || !a.has(Kw.provoke)) continue;
        bool blocked;
        foreach (x; as_) if (x is a) blocked = true;
        if (blocked) continue;
        foreach (b; g.field)
        {
            bool used;
            foreach (x; bs) if (x is b) used = true;
            if (!used && canBlock(g, b, a)) return "missing-required-block";
        }
    }
    return null;
}

/// 19.1: declare attackers (already validated, any order).
void declareAttackers(Game g, Obj[] list)
{
    list.sort!((a, b) => a.oid < b.oid);
    foreach (o; list)
    {
        o.attacking = true;
        g.dirty = true;
        ensureDerived(g);
        if (!o.has(Kw.vigil)) setExhausted(g, o, true);
        g.emit("ATTACK", Game.r(o));
    }
    foreach (o; list) collectFrom(g, o, Event.attacks, Subject.ofObj(o.oid));
}

/// 19.3: declare blockers (already validated).
void declareBlockers(Game g, Obj[] bs, Obj[] as_)
{
    size_t[] order;
    foreach (i; 0 .. bs.length) order ~= i;
    order.sort!((x, y) => bs[x].oid < bs[y].oid);
    foreach (i; order)
    {
        auto b = bs[i];
        auto a = as_[i];
        b.blocking = true;
        b.blockedAttacker = a;
        a.blockers ~= b;
        a.blockedFlag = true;
        g.dirty = true;
        g.emit("BLOCK", Game.r(b), Game.r(a));
    }
    Obj[] attackers;
    foreach (o; g.field) if (o.attacking) attackers ~= o;
    attackers.sort!((a, b) => a.oid < b.oid);
    foreach (a; attackers) sortCanon(a.blockers);
    Obj[] unblocked;
    foreach (a; attackers)
        if (a.blockers.length == 0) { unblocked ~= a; g.emit("UNBLOCKED", Game.r(a)); }
    foreach (i; order) collectFrom(g, bs[i], Event.blocks, Subject.ofObj(as_[i].oid));
    foreach (a; attackers)
        if (a.blockers.length > 0) collectFrom(g, a, Event.blocked, Subject.ofObj(a.blockers[0].oid));
    foreach (a; unblocked) collectFrom(g, a, Event.unblocked, Subject.ofObj(a.oid));
}

/// Units currently in combat, in canonical order.
Obj[] inCombat(Game g)
{
    Obj[] r;
    foreach (o; g.field) if (o.attacking || o.blocking) r ~= o;
    return r;
}

private struct Assign { Obj src; Target tgt; long amt; }

/// Deal the combat damage of exactly the units in `dealers` (19.6, 17.2).
void dealCombatDamage(Game g, Obj[] dealers)
{
    ensureDerived(g);
    Assign[] list;
    auto defender = Target.ofPlayer(opponent(g.active));
    foreach (u; dealers)
    {
        immutable e = u.edge;
        if (e <= 0) continue;
        if (u.blocking)
        {
            if (u.blockedAttacker !is null) list ~= Assign(u, Target.ofObj(u.blockedAttacker.oid), e);
        }
        else if (u.attacking && !u.blockedFlag)
            list ~= Assign(u, defender, e);
        else if (u.attacking)
        {
            Obj[] L;
            foreach (b; u.blockers)
                if (b.zone == Zone.field && b.blocking && b.blockedAttacker is u) L ~= b;
            if (L.length == 0) continue;
            long r = e;
            long[] amts = new long[L.length];
            foreach (i, b; L)
            {
                immutable need = u.has(Kw.venom) ? 1L : max(0L, b.core - b.wounds);
                amts[i] = min(r, need);
                r -= amts[i];
            }
            if (r > 0)
            {
                if (u.has(Kw.pierce)) list ~= Assign(u, defender, r);
                else amts[$ - 1] += r;
            }
            foreach (i, b; L)
                if (amts[i] > 0) list ~= Assign(u, Target.ofObj(b.oid), amts[i]);
        }
    }
    list.sort!((a, b)
    {
        auto ka = [1L, a.src.ts, a.src.oid], kb = [1L, b.src.ts, b.src.oid];
        if (ka != kb) return ka < kb;
        return targetKey(g, a.tgt) < targetKey(g, b.tgt);
    });
    foreach (a; list) dealDamage(g, a.src, a.tgt, a.amt);
}

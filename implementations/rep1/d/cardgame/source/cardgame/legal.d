/**
 * Enumeration of the legal actions at the current decision point
 * (SPEC.md section 21).
 */
module cardgame.legal;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;
import cardgame.chain;
import cardgame.combat;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.select;

/// Every tuple of distinct targets drawn from per-spec candidate lists, in lexicographic key order.
private void tuples(Game g, Target[][] cands, size_t i, ref Target[] cur, void delegate(Target[]) emit)
{
    if (i == cands.length) { emit(cur); return; }
    foreach (t; cands[i])
    {
        bool dup;
        foreach (x; cur) if (x.kind == t.kind && x.id == t.id) dup = true;
        if (dup) continue;
        cur ~= t;
        tuples(g, cands, i + 1, cur, emit);
        cur = cur[0 .. $ - 1];
    }
}

private string targetSuffix(Game g, Target[] ts)
{
    string s;
    foreach (t; ts) s ~= " " ~ g.render(t);
    return s;
}

/// The action lines of the `LEGAL` block for the current decision.
string[] legalActions(Game g)
{
    string[] r;
    if (g.decision == Decision.over) return r;
    final switch (g.decision)
    {
    case Decision.priority:
    {
        auto p = g.decisionPlayer;
        r ~= "PASS";
        auto hand = g.pl[p].hand;
        foreach (i, o; hand)
        {
            if (!playTimingOk(g, p, o.card)) continue;
            if (g.pl[p].ember < playCost(g, p, o.card)) continue;
            auto specs = playSpecs(o.card);
            Target[][] cands;
            foreach (s; specs) cands ~= candidates(g, s, p, o, g.nextCid);
            Target[] cur;
            string prefix = "PLAY " ~ (i + 1).to!string ~ " " ~ o.card.id;
            tuples(g, cands, 0, cur, (Target[] ts) { r ~= prefix ~ targetSuffix(g, ts); });
        }
        ensureDerived(g);
        Obj[] mine;
        foreach (o; g.field) if (o.ctrl == p && !o.stripped) mine ~= o;
        mine.sort!((a, b) => a.oid < b.oid);
        foreach (o; mine)
            foreach (ab; o.card.abilities)
            {
                if (ab.kind != AbilityKind.act) continue;
                Target[] none;
                bool payable = true;
                foreach (c; ab.costs)
                    if (!costOk(g, p, o, c, ab.index)) { payable = false; break; }
                if (!payable) continue;
                Target[][] cands;
                foreach (s; ab.targets) cands ~= candidates(g, s, p, o, g.nextCid);
                Target[] cur;
                string prefix = "ACT " ~ Game.r(o) ~ " " ~ ab.index.to!string;
                tuples(g, cands, 0, cur, (Target[] ts) { r ~= prefix ~ targetSuffix(g, ts); });
            }
        break;
    }
    case Decision.attackers:
    {
        Obj[] can;
        foreach (o; g.field) if (canAttack(g, o)) can ~= o;
        can.sort!((a, b) => a.oid < b.oid);
        foreach (o; can) r ~= "CANATTACK " ~ Game.r(o);
        foreach (o; can) if (o.has(Kw.relentless)) r ~= "MUSTATTACK " ~ Game.r(o);
        break;
    }
    case Decision.blockers:
    {
        Obj[] byOid = g.field.dup;
        byOid.sort!((a, b) => a.oid < b.oid);
        foreach (b; byOid)
            foreach (a; byOid)
                if (canBlock(g, b, a)) r ~= "CANBLOCK " ~ Game.r(b) ~ " " ~ Game.r(a);
        foreach (a; byOid) if (a.attacking && a.has(Kw.provoke)) r ~= "MUSTBLOCK " ~ Game.r(a);
        break;
    }
    case Decision.over: break;
    }
    return r;
}

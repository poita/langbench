/**
 * Inspection blocks: `DUMP`, `LEGAL`, `VAULT` and `CARD` (SPEC section 23).
 */
module cardgame.report;

import std.algorithm : sort;
import std.array : appender, join;
import std.conv : to;

import cardgame.cards;
import cardgame.derive;
import cardgame.effects;
import cardgame.engine;
import cardgame.eval;
import cardgame.game;
import cardgame.sexpr;

private string pl(int p)
{
    return p == 0 ? "A" : "B";
}

private string render(Target t)
{
    final switch (t.kind)
    {
    case 0:
        return pl(t.id);
    case 1:
        return "#" ~ t.id.to!string;
    case 2:
        return "~" ~ t.id.to!string;
    }
}

private string renderAll(Target[] ts, bool[] removed = null)
{
    string s;
    foreach (i, t; ts)
        s ~= " " ~ ((removed.length > i && removed[i]) ? "-" : render(t));
    return s;
}

private string kwList(Game g, int oid)
{
    string[] names;
    long plating;
    bool hasPlating;
    foreach (k; g.objs[oid].kws)
    {
        if (k.kind == Keyword.plating)
        {
            plating += k.value;
            hasPlating = true;
            continue;
        }
        immutable n = keywordName(k.kind);
        bool dup = false;
        foreach (m; names)
            dup = dup || m == n;
        if (!dup)
            names ~= n;
    }
    if (hasPlating)
        names ~= "plating:" ~ plating.to!string;
    if (names.length == 0)
        return "-";
    names.sort();
    return names.join(",");
}

private string flagList(Game g, int oid)
{
    auto o = &g.objs[oid];
    string[] f;
    if (o.attacking)
        f ~= "attacking";
    if (o.blocked)
        f ~= "blocked";
    if (o.blocking)
        f ~= "blocking";
    if (o.doomed)
        f ~= "doomed";
    foreach (i; 0 .. 64)
        if (o.onceMask & (1UL << i))
            f ~= "once" ~ i.to!string;
    if (g.isSettling(oid))
        f ~= "settling";
    if (o.tenUsed)
        f ~= "tenacity-used";
    if (o.ward > 0)
        f ~= "ward" ~ o.ward.to!string;
    if (f.length == 0)
        return "-";
    f.sort();
    return f.join(",");
}

private string objList(int[] ids)
{
    if (ids.length == 0)
        return "-";
    string[] s;
    foreach (i; ids)
        s ~= "#" ~ i.to!string;
    return s.join(",");
}

private string describeLeaf(ref Leaf l)
{
    final switch (l.kind)
    {
    case StKind.modify:
        return "modify " ~ l.a.to!string ~ " " ~ l.b.to!string;
    case StKind.setbody:
        return "setbody " ~ l.a.to!string ~ " " ~ l.b.to!string;
    case StKind.swapstats:
        return "swapstats";
    case StKind.grant:
        return "grant " ~ kwString(l.kw);
    case StKind.cheaper:
        return "cheaper " ~ l.n.to!string;
    case StKind.when:
        return "";
    }
}

/// Write the `DUMP` block.
void writeDump(Game g)
{
    ensureDerived(g);
    g.raw("STATE BEGIN");
    if (g.over)
        g.raw("turn " ~ g.turn.to!string ~ " active " ~ pl(g.active) ~ " phase "
                ~ phaseNames[g.phase] ~ " decision - over");
    else
    {
        immutable kind = g.dec == DecKind.priority ? "priority" : g.dec == DecKind.attackers
            ? "attackers" : "blockers";
        g.raw("turn " ~ g.turn.to!string ~ " active " ~ pl(g.active) ~ " phase "
                ~ phaseNames[g.phase] ~ " decision " ~ pl(g.holder) ~ " " ~ kind);
    }
    if (g.over)
        g.raw("result " ~ g.resultWinner ~ " " ~ g.resultReason);
    foreach (p; 0 .. 2)
        g.raw("player " ~ pl(p) ~ " spire " ~ g.spire[p].to!string ~ " ember "
                ~ g.ember[p].to!string ~ " cap " ~ g.cap[p].to!string ~ " vault "
                ~ g.vault[p].length.to!string ~ " hand " ~ g.hand[p].length.to!string
                ~ " ash " ~ g.ash[p].length.to!string ~ " rift " ~ g.rift[p].length.to!string);
    foreach (p; 0 .. 2)
        foreach (i, oid; g.hand[p])
            g.raw("hand " ~ pl(p) ~ " " ~ (i + 1).to!string ~ " #" ~ oid.to!string ~ " " ~ g.cardOf(oid).id);
    foreach (p; 0 .. 2)
        foreach (oid; g.field)
        {
            if (g.objs[oid].cur != p)
                continue;
            auto o = &g.objs[oid];
            auto card = g.cardOf(oid);
            immutable body_ = card.type == CardType.relic ? "-/-" : o.edge.to!string ~ "/" ~ o.core.to!string;
            g.raw("field " ~ pl(p) ~ " #" ~ oid.to!string ~ " " ~ card.id ~ " " ~ body_ ~ " w"
                    ~ o.wounds.to!string ~ " c" ~ o.counters.to!string ~ " "
                    ~ (o.exhausted ? "exhausted" : "ready") ~ " " ~ flagList(g, oid) ~ " kw " ~ kwList(g, oid));
        }
    foreach (p; 0 .. 2)
        foreach (i, oid; g.ash[p])
            g.raw("ash " ~ pl(p) ~ " " ~ (i + 1).to!string ~ " #" ~ oid.to!string ~ " " ~ g.cardOf(oid).id);
    foreach (p; 0 .. 2)
        foreach (i, oid; g.rift[p])
            g.raw("rift " ~ pl(p) ~ " " ~ (i + 1).to!string ~ " #" ~ oid.to!string ~ " " ~ g.cardOf(oid).id);
    foreach (i, e; g.chain)
        g.raw("chain " ~ (i + 1).to!string ~ " ~" ~ e.cid.to!string ~ " " ~ pl(e.ctrl) ~ " "
                ~ entryKindNames[e.kind] ~ " #" ~ e.src.to!string ~ " " ~ e.abil.to!string
                ~ renderAll(e.targets, e.removed));
    foreach (r; g.recs)
    {
        if (r.aura)
        {
            if (r.leaves.length == 0)
                continue;
            auto l = &r.leaves[0];
            g.raw("effect " ~ r.eid.to!string ~ " ts" ~ r.ts.to!string ~ " " ~ pl(r.ctrl)
                    ~ " aura " ~ describeLeaf(*l) ~ " on "
                    ~ (l.kind == StKind.cheaper ? "-" : objList(l.active ? l.affected : null)));
            continue;
        }
        string desc;
        final switch (r.kind)
        {
        case RecKind.modify:
            desc = "modify " ~ r.a.to!string ~ " " ~ r.b.to!string;
            break;
        case RecKind.setbody:
            desc = "setbody " ~ r.a.to!string ~ " " ~ r.b.to!string;
            break;
        case RecKind.swapstats:
            desc = "swapstats";
            break;
        case RecKind.grant:
            desc = "grant " ~ kwString(r.kw);
            break;
        case RecKind.strip:
            desc = "strip";
            break;
        case RecKind.control:
            desc = "control " ~ pl(r.ctrl);
            break;
        case RecKind.cheaper:
            desc = "cheaper " ~ r.n.to!string;
            break;
        }
        int[] on;
        foreach (a; r.affected)
            if (g.onField(a))
                on ~= a;
        g.raw("effect " ~ r.eid.to!string ~ " ts" ~ r.ts.to!string ~ " " ~ pl(r.ctrl) ~ " turn "
                ~ desc ~ " on " ~ objList(on));
    }
    foreach (d; g.delayed)
        g.raw("delayed " ~ d.ts.to!string ~ " " ~ pl(d.ctrl) ~ " " ~ delayName(d.when) ~ renderAll(d.targets));
    g.raw("STATE END");
}

/// Write the `VAULT` block.
void writeVault(Game g)
{
    g.raw("VAULT BEGIN");
    foreach (p; 0 .. 2)
        foreach (i, oid; g.vault[p])
            g.raw("vault " ~ pl(p) ~ " " ~ (i + 1).to!string ~ " #" ~ oid.to!string ~ " " ~ g.cardOf(oid).id);
    g.raw("VAULT END");
}

/// Write the `LEGAL` block (SPEC 21).
void writeLegal(Game g)
{
    if (g.over)
    {
        g.raw("LEGAL BEGIN - over");
        g.raw("LEGAL END");
        return;
    }
    ensureDerived(g);
    final switch (g.dec)
    {
    case DecKind.priority:
        g.raw("LEGAL BEGIN " ~ pl(g.holder) ~ " priority");
        legalPriority(g);
        break;
    case DecKind.attackers:
        g.raw("LEGAL BEGIN " ~ pl(g.holder) ~ " attackers");
        int[] can;
        foreach (oid; g.field)
            if (canAttack(g, oid))
                can ~= oid;
        can.sort();
        foreach (oid; can)
            g.raw("CANATTACK #" ~ oid.to!string);
        foreach (oid; can)
            if (g.hasKw(oid, Keyword.relentless))
                g.raw("MUSTATTACK #" ~ oid.to!string);
        break;
    case DecKind.blockers:
        g.raw("LEGAL BEGIN " ~ pl(g.holder) ~ " blockers");
        int[] blockers, attackers;
        foreach (oid; g.field)
        {
            if (g.objs[oid].attacking)
                attackers ~= oid;
            if (g.ctl(oid) == g.holder)
                blockers ~= oid;
        }
        blockers.sort();
        attackers.sort();
        foreach (b; blockers)
            foreach (a; attackers)
                if (canBlock(g, b, a))
                    g.raw("CANBLOCK #" ~ b.to!string ~ " #" ~ a.to!string);
        foreach (a; attackers)
            if (g.hasKw(a, Keyword.provoke))
                g.raw("MUSTBLOCK #" ~ a.to!string);
        break;
    case DecKind.none:
        g.raw("LEGAL BEGIN - over");
        break;
    }
    g.raw("LEGAL END");
}

private void legalPriority(Game g)
{
    immutable p = g.holder;
    g.raw("PASS");
    foreach (i, oid; g.hand[p])
    {
        auto card = g.cardOf(oid);
        immutable swift = card.type == CardType.rite && card.hasKeyword(Keyword.swift);
        if (!swift && !(g.active == p && (g.phase == Phase.main1 || g.phase == Phase.main2)
                && g.chain.length == 0))
            continue;
        if (g.ember[p] < effectiveCost(g, p, card))
            continue;
        TSpec[] specs = card.type == CardType.rite ? card.abilities[0].targets : null;
        foreach (tuple; targetTuples(g, specs, p, oid, g.nextCid))
            g.raw("PLAY " ~ (i + 1).to!string ~ " " ~ card.id ~ renderAll(tuple));
    }
    int[] mine;
    foreach (oid; g.field)
        if (g.ctl(oid) == p)
            mine ~= oid;
    mine.sort();
    foreach (oid; mine)
    {
        auto card = g.cardOf(oid);
        if (g.isStripped(oid))
            continue;
        foreach (idx, ab; card.abilities)
        {
            if (ab.kind != AbilKind.act || !costsPayable(g, p, oid, cast(int) idx + 1, ab))
                continue;
            foreach (tuple; targetTuples(g, ab.targets, p, oid, g.nextCid))
                g.raw("ACT #" ~ oid.to!string ~ " " ~ (idx + 1).to!string ~ renderAll(tuple));
        }
    }
}

private string kwDisplay(Kw k)
{
    return kwString(k);
}

/// Write the `CARD` block (SPEC 23.4).
void writeCard(Game g, string id)
{
    g.raw("CARD BEGIN " ~ id);
    auto card = g.db.find(id);
    if (card is null)
    {
        g.raw("unknown");
        g.raw("CARD END");
        return;
    }
    g.raw("name " ~ card.name);
    g.raw("type " ~ (card.type == CardType.unit ? "unit" : card.type == CardType.rite ? "rite" : "relic"));
    g.raw("cost " ~ card.cost.to!string);
    if (card.type == CardType.unit)
        g.raw("body " ~ card.edge.to!string ~ "/" ~ card.core.to!string);
    g.raw("tags " ~ (card.tags.length ? card.tags.join(",") : "-"));
    string[] kws;
    foreach (k; card.keywords)
        kws ~= kwDisplay(k);
    kws.sort();
    g.raw("keywords " ~ (kws.length ? kws.join(",") : "-"));
    foreach (i, ab; card.abilities)
    {
        string[] bodyParts;
        foreach (b; ab.bodyRaw)
            bodyParts ~= printSExpr(b);
        immutable body_ = bodyParts.join(" ");
        immutable tspec = ab.targetsRaw is null ? "-" : printSExpr(ab.targetsRaw);
        string line;
        final switch (ab.kind)
        {
        case AbilKind.resolve:
            line = "resolve " ~ tspec ~ " " ~ body_;
            break;
        case AbilKind.on:
            line = "on " ~ eventName(ab.event) ~ " " ~ tspec ~ " " ~ body_;
            break;
        case AbilKind.act:
            line = "act " ~ (ab.costRaw is null ? "-" : printSExpr(ab.costRaw)) ~ " " ~ tspec ~ " " ~ body_;
            break;
        case AbilKind.aura:
            line = "aura " ~ body_;
            break;
        }
        g.raw("ability " ~ (i + 1).to!string ~ " " ~ line);
    }
    g.raw("CARD END");
}

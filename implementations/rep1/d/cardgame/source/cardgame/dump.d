/**
 * Inspection blocks: `DUMP`, `LEGAL`, `VAULT` and `CARD` (SPEC.md section 23).
 */
module cardgame.dump;

import std.algorithm : sort, map;
import std.array : appender, join;
import std.conv : to;
import cardgame.database;
import cardgame.game;
import cardgame.layers;
import cardgame.legal;
import cardgame.model;
import cardgame.select;
import cardgame.sexpr;

private string kwList(const Obj o)
{
    string[] names;
    foreach (i, n; keywordNames)
    {
        immutable k = cast(Kw) i;
        if (!o.has(k)) continue;
        names ~= k == Kw.plating ? "plating:" ~ o.platingSum.to!string : n;
    }
    names.sort();
    return names.length ? names.join(",") : "-";
}

private string flagList(Game g, const Obj o)
{
    string[] f;
    if (o.attacking) f ~= "attacking";
    if (o.blockedFlag) f ~= "blocked";
    if (o.blocking) f ~= "blocking";
    if (o.doomed) f ~= "doomed";
    foreach (i; o.usedOnce) f ~= "once" ~ i.to!string;
    if (isSettling(g, o)) f ~= "settling";
    if (o.tenacityUsed) f ~= "tenacity-used";
    if (o.ward > 0) f ~= "ward" ~ o.ward.to!string;
    f.sort();
    return f.length ? f.join(",") : "-";
}

private string objList(const(Obj)[] os)
{
    if (os.length == 0) return "-";
    string[] r;
    foreach (o; os) r ~= "#" ~ o.oid.to!string;
    return r.join(",");
}

private string partDesc(const ref RecPart p)
{
    final switch (p.kind)
    {
    case RecKind.modify: return "modify " ~ p.a.to!string ~ " " ~ p.b.to!string;
    case RecKind.setbody: return "setbody " ~ p.a.to!string ~ " " ~ p.b.to!string;
    case RecKind.swapstats: return "swapstats";
    case RecKind.grant: return "grant " ~ p.kw.render();
    case RecKind.strip: return "strip";
    case RecKind.control: return "control";
    case RecKind.cheaper: return "cheaper " ~ p.cheaperBy.to!string;
    }
}

private string entryKind(EntryKind k)
{
    final switch (k)
    {
    case EntryKind.rite: return "rite";
    case EntryKind.unit: return "unit";
    case EntryKind.relic: return "relic";
    case EntryKind.ability: return "ability";
    case EntryKind.trigger: return "trigger";
    }
}

/// The `DUMP` block.
string dumpState(Game g)
{
    ensureDerived(g);
    string[] L;
    L ~= "STATE BEGIN";
    string dec;
    final switch (g.decision)
    {
    case Decision.priority: dec = Game.r(g.decisionPlayer) ~ " priority"; break;
    case Decision.attackers: dec = Game.r(g.decisionPlayer) ~ " attackers"; break;
    case Decision.blockers: dec = Game.r(g.decisionPlayer) ~ " blockers"; break;
    case Decision.over: dec = "- over"; break;
    }
    if (g.ended) dec = "- over";
    L ~= "turn " ~ g.turn.to!string ~ " active " ~ Game.r(g.active) ~ " phase " ~ g.phase ~ " decision " ~ dec;
    if (g.ended) L ~= "result " ~ g.resultWinner ~ " " ~ g.resultReason;
    foreach (p; [Player.A, Player.B])
    {
        auto s = g.pl[p];
        L ~= "player " ~ Game.r(p) ~ " spire " ~ s.spire.to!string ~ " ember " ~ s.ember.to!string
            ~ " cap " ~ s.cap.to!string ~ " vault " ~ s.vault.length.to!string
            ~ " hand " ~ s.hand.length.to!string ~ " ash " ~ s.ash.length.to!string
            ~ " rift " ~ s.rift.length.to!string;
    }
    foreach (p; [Player.A, Player.B])
        foreach (i, o; g.pl[p].hand)
            L ~= "hand " ~ Game.r(p) ~ " " ~ (i + 1).to!string ~ " " ~ Game.r(o) ~ " " ~ o.card.id;
    foreach (p; [Player.A, Player.B])
        foreach (o; g.field)
        {
            if (o.ctrl != p) continue;
            string body_ = o.isUnit ? o.edge.to!string ~ "/" ~ o.core.to!string : "-/-";
            L ~= "field " ~ Game.r(p) ~ " " ~ Game.r(o) ~ " " ~ o.card.id ~ " " ~ body_ ~ " w" ~ o.wounds.to!string
                ~ " c" ~ o.counters.to!string ~ " " ~ (o.exhausted ? "exhausted" : "ready") ~ " "
                ~ flagList(g, o) ~ " kw " ~ kwList(o);
        }
    foreach (p; [Player.A, Player.B])
        foreach (i, o; g.pl[p].ash)
            L ~= "ash " ~ Game.r(p) ~ " " ~ (i + 1).to!string ~ " " ~ Game.r(o) ~ " " ~ o.card.id;
    foreach (p; [Player.A, Player.B])
        foreach (i, o; g.pl[p].rift)
            L ~= "rift " ~ Game.r(p) ~ " " ~ (i + 1).to!string ~ " " ~ Game.r(o) ~ " " ~ o.card.id;
    foreach (i, e; g.chain)
    {
        string line = "chain " ~ (i + 1).to!string ~ " ~" ~ e.cid.to!string ~ " " ~ Game.r(e.ctrl) ~ " "
            ~ entryKind(e.kind) ~ " " ~ Game.r(e.src) ~ " " ~ e.abilityIndex.to!string;
        foreach (t; e.targets) line ~= " " ~ (t.removed ? "-" : g.render(t));
        L ~= line;
    }
    foreach (r; g.records)
    {
        string line = "effect " ~ r.eid.to!string ~ " ts" ~ r.ts.to!string ~ " " ~ Game.r(r.ctrl) ~ " ";
        if (r.aura)
        {
            if (r.parts.length == 0) continue;
            auto p = r.parts[0];
            line ~= "aura " ~ partDesc(p) ~ " on " ~ (p.kind == RecKind.cheaper ? "-" : objList(p.affected));
        }
        else
        {
            RecPart p;
            p.kind = r.kind; p.a = r.a; p.b = r.b; p.kw = r.kw;
            string desc = r.kind == RecKind.control ? "control " ~ Game.r(r.ctrl) : partDesc(p);
            Obj[] on;
            foreach (oid; r.affected) if (g.objs[oid].zone == Zone.field) on ~= g.objs[oid];
            line ~= "turn " ~ desc ~ " on " ~ objList(on);
        }
        L ~= line;
    }
    foreach (d; g.delayed)
    {
        string line = "delayed " ~ d.ts.to!string ~ " " ~ Game.r(d.ctrl) ~ " " ~ whenNames[d.when];
        foreach (t; d.targets) line ~= " " ~ g.render(t);
        L ~= line;
    }
    L ~= "STATE END";
    return L.join("\n");
}

/// The `LEGAL` block.
string legalBlock(Game g)
{
    string head = g.decision == Decision.over || g.ended ? "LEGAL BEGIN - over"
        : "LEGAL BEGIN " ~ Game.r(g.decisionPlayer) ~ " "
          ~ (g.decision == Decision.priority ? "priority" : g.decision == Decision.attackers ? "attackers" : "blockers");
    string[] L = [head];
    if (!g.ended) L ~= legalActions(g);
    L ~= "LEGAL END";
    return L.join("\n");
}

/// The `VAULT` block.
string vaultBlock(Game g)
{
    string[] L = ["VAULT BEGIN"];
    foreach (p; [Player.A, Player.B])
        foreach (i, o; g.pl[p].vault.items)
            L ~= "vault " ~ Game.r(p) ~ " " ~ (i + 1).to!string ~ " " ~ Game.r(o) ~ " " ~ o.card.id;
    L ~= "VAULT END";
    return L.join("\n");
}

/// The `CARD` block for `id`.
string cardBlock(Database db, string id)
{
    string[] L = ["CARD BEGIN " ~ id];
    auto c = db.find(id);
    if (c is null)
    {
        L ~= "unknown";
    }
    else
    {
        L ~= "name " ~ c.name;
        L ~= "type " ~ c.type.to!string;
        L ~= "cost " ~ c.cost.to!string;
        if (c.type == CardType.unit) L ~= "body " ~ c.edge.to!string ~ "/" ~ c.core.to!string;
        L ~= "tags " ~ (c.tags.length ? c.tags.join(",") : "-");
        string[] kws;
        foreach (k; c.keywords) kws ~= k.render();
        kws.sort();
        L ~= "keywords " ~ (kws.length ? kws.join(",") : "-");
        foreach (ab; c.abilities)
        {
            string tspec = ab.hasTargets ? printSExpr(ab.targetsClause) : "-";
            string line = "ability " ~ ab.index.to!string ~ " ";
            final switch (ab.kind)
            {
            case AbilityKind.resolve: line ~= "resolve " ~ tspec; break;
            case AbilityKind.on: line ~= "on " ~ eventNames[ab.event] ~ " " ~ tspec; break;
            case AbilityKind.act: line ~= "act " ~ printSExpr(ab.costClause) ~ " " ~ tspec; break;
            case AbilityKind.aura: line ~= "aura"; break;
            }
            foreach (part; ab.rawParts) line ~= " " ~ printSExpr(part);
            L ~= line;
        }
    }
    L ~= "CARD END";
    return L.join("\n");
}

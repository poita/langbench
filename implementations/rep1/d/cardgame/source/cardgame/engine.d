/**
 * The rules engine: the Chain, priority, settling, state checks, the turn
 * machine, combat, and the six player actions.
 *
 * The engine is a resumable state machine. `advance` runs forward until a
 * decision point (`Game.dec`) is reached or the match ends; each accepted
 * action mutates the state and calls `advance` again.
 */
module cardgame.engine;

import std.algorithm : sort, min;
import std.range : empty;

import cardgame.actions;
import cardgame.cards;
import cardgame.derive;
import cardgame.effects;
import cardgame.eval;
import cardgame.game;

// ------------------------------------------------------------- match ending

/// End the match (SPEC 20): emit `LOSE` lines and the single `RESULT` line.
void endMatch(Game g, bool turnLimit = false)
{
    g.over = true;
    g.dec = DecKind.none;
    g.touch();
    if (turnLimit)
    {
        g.turnLimitDraw = true;
        g.resultWinner = "draw";
        g.resultReason = "turn-limit";
    }
    else
    {
        foreach (p; 0 .. 2)
            if (g.loss[p] != Loss.none)
                g.ev("LOSE", Pl(p), lossNames[g.loss[p]]);
        if (g.loss[0] != Loss.none && g.loss[1] != Loss.none)
        {
            g.resultWinner = "draw";
            g.resultReason = lossNames[g.loss[0]];
        }
        else if (g.loss[0] != Loss.none)
        {
            g.resultWinner = "B";
            g.resultReason = lossNames[g.loss[0]];
        }
        else
        {
            g.resultWinner = "A";
            g.resultReason = lossNames[g.loss[1]];
        }
    }
    g.ev("RESULT", g.resultWinner, g.resultReason);
}

// ---------------------------------------------------- state checks, settling

/// One run of the state checks (SPEC 18); true if it acted.
bool stateChecks(Game g)
{
    foreach (p; 0 .. 2)
        if (g.spire[p] <= 0)
            recordLoss(g, p, Loss.spire);
    if (g.loss[0] != Loss.none || g.loss[1] != Loss.none)
    {
        endMatch(g);
        return true;
    }
    ensureDerived(g);
    int[] doomed;
    foreach (oid; g.field)
    {
        if (g.cardOf(oid).type != CardType.unit)
            continue;
        if (g.objs[oid].core <= g.objs[oid].wounds || g.objs[oid].doomed)
            doomed ~= oid;
    }
    if (doomed.empty)
        return false;
    foreach (oid; doomed)
        destroyObj(g, oid);
    return true;
}

/// Push the pending triggers onto the Chain (SPEC 13.3); true if any were pending.
bool pushTriggers(Game g)
{
    if (g.pending.length == 0)
        return false;
    auto list = g.pending;
    g.pending = null;
    foreach (ref p; list)
        p.side = p.ctrl == g.active ? 0 : 1;
    list.sort!((a, b) {
        if (a.side != b.side)
            return a.side < b.side;
        if (a.ts != b.ts)
            return a.ts < b.ts;
        if (a.oid != b.oid)
            return a.oid < b.oid;
        if (a.abil != b.abil)
            return a.abil < b.abil;
        return a.seq < b.seq;
    });
    Entry[] batch;
    foreach (p; list)
    {
        auto e = new Entry;
        e.kind = EntryKind.trigger;
        e.ctrl = p.ctrl;
        e.src = p.oid;
        e.abil = p.abil;
        e.it = p.it;
        if (p.delayed !is null)
        {
            e.targets = p.delayed.targets.dup;
            e.specs = p.delayed.specs;
            e.delayedEffects = p.delayed.effects;
        }
        else
        {
            auto ab = g.cardOf(p.oid).abilities[p.abil - 1];
            if (ab.targets.length)
            {
                Target[] chosen;
                if (!autoTargets(g, ab.targets, p.ctrl, p.oid, chosen))
                {
                    g.ev("TRIGGER-NO-TARGET", Pl(p.ctrl), O(p.oid), p.abil);
                    continue;
                }
                e.targets = chosen;
                e.specs = ab.targets;
            }
        }
        e.removed = new bool[e.targets.length];
        e.cid = g.nextCid++;
        g.ev("TRIGGER", Pl(p.ctrl), Q(e.cid), O(p.oid), p.abil, e.targets);
        batch ~= e;
    }
    foreach_reverse (e; batch)
        g.chain ~= e;
    return true;
}

/// Run state checks and trigger pushes until quiescent (SPEC 10.5).
bool settle(Game g)
{
    bool acted = false;
    while (true)
    {
        immutable a = stateChecks(g);
        if (g.over)
            return true;
        immutable b = pushTriggers(g);
        acted = acted || a || b;
        if (!a && !b)
            break;
    }
    return acted;
}

/// Resolve the top Chain entry (SPEC 11.6).
void resolveTop(Game g)
{
    auto e = g.chain[$ - 1];
    g.ev("RESOLVE", Q(e.cid));
    bool allRemoved = e.targets.length > 0;
    foreach (i, t; e.targets)
    {
        immutable legal = targetLegal(g, e.specs[i], t, e.ctrl, e.src, e.cid);
        e.removed[i] = !legal;
        if (legal)
            allRemoved = false;
    }
    g.chain = g.chain[0 .. $ - 1];
    if (allRemoved)
        g.ev("FIZZLE", Q(e.cid));
    else
    {
        auto c = Ctx(e.ctrl, e.src, e, e.it);
        final switch (e.kind)
        {
        case EntryKind.rite:
            execEffects(g, g.cardOf(e.src).abilities[0].effects, c);
            break;
        case EntryKind.unit:
        case EntryKind.relic:
            enterField(g, e.src, e.ctrl);
            break;
        case EntryKind.ability:
        case EntryKind.trigger:
            if (e.abil == 0)
                execEffects(g, e.delayedEffects, c);
            else
                execEffects(g, g.cardOf(e.src).abilities[e.abil - 1].effects, c);
            break;
        }
    }
    if (e.kind == EntryKind.rite)
    {
        putInZone(g, e.src, ZoneKind.ash);
        g.ev("SPENT", O(e.src), g.cardOf(e.src).id);
    }
    else if ((e.kind == EntryKind.unit || e.kind == EntryKind.relic) && allRemoved)
        putInZone(g, e.src, ZoneKind.ash);
}

/// Settle and resolve until the Chain is empty (SPEC 10.6).
void drain(Game g)
{
    while (true)
    {
        settle(g);
        if (g.over || g.chain.length == 0)
            return;
        resolveTop(g);
    }
}

// ------------------------------------------------------------- turn machine

private void startRound(Game g)
{
    g.passCount = 0;
    settle(g);
    if (g.over)
        return;
    g.holder = g.active;
    g.dec = DecKind.priority;
}

private void enterPhase(Game g, Phase p)
{
    g.phase = p;
    g.ev("PHASE", phaseNames[p]);
}

private void collectDelayed(Game g, DelayWhen when)
{
    size_t w = 0;
    foreach (d; g.delayed)
    {
        immutable fire = d.when == when && (when != DelayWhen.yourNextTurnStart || d.ctrl == g.active);
        if (fire)
        {
            Pending p;
            p.ts = d.ts;
            p.oid = d.src;
            p.abil = 0;
            p.ctrl = d.ctrl;
            p.delayed = d;
            p.seq = g.pendingSeq++;
            g.pending ~= p;
        }
        else
            g.delayed[w++] = d;
    }
    g.delayed = g.delayed[0 .. w];
}

/// Is the unit in combat?
bool inCombat(Game g, int oid)
{
    return g.onField(oid) && (g.objs[oid].attacking || g.objs[oid].blocking);
}

private void clearCombat(Game g)
{
    foreach (oid; g.field)
    {
        auto o = &g.objs[oid];
        o.attacking = o.blocking = o.blocked = false;
        o.blockTarget = 0;
        o.blockers.length = 0;
    }
    g.riposters = null;
    g.touchDep(Dep.combat);
}

/// Run the turn machine until the next decision point or the end of the match.
void advance(Game g)
{
    while (!g.over && g.dec == DecKind.none)
    {
        final switch (g.next)
        {
        case Step.turnStart:
            g.ev("TURN", g.turn, Pl(g.active));
            g.next = Step.dawn;
            break;
        case Step.dawn:
            stepDawn(g);
            g.next = Step.draw;
            break;
        case Step.draw:
            enterPhase(g, Phase.draw);
            if (!(g.turn == 1 && g.active == g.first))
                drawCards(g, g.active, 1);
            drain(g);
            g.next = Step.main1;
            break;
        case Step.main1:
            enterPhase(g, Phase.main1);
            startRound(g);
            break;
        case Step.clashAttack:
            enterPhase(g, Phase.clashAttack);
            settle(g);
            if (g.over)
                break;
            g.holder = g.active;
            g.dec = DecKind.attackers;
            break;
        case Step.clashBlock:
            enterPhase(g, Phase.clashBlock);
            settle(g);
            if (g.over)
                break;
            g.holder = 1 - g.active;
            g.dec = DecKind.blockers;
            break;
        case Step.clashRiposte:
            enterPhase(g, Phase.clashRiposte);
            dealCombatDamage(g, true);
            startRound(g);
            break;
        case Step.clashDamage:
            enterPhase(g, Phase.clashDamage);
            dealCombatDamage(g, false);
            startRound(g);
            break;
        case Step.clashEnd:
            enterPhase(g, Phase.clashEnd);
            foreach (oid; g.field.dup)
                if (inCombat(g, oid))
                    collectSelf(g, oid, Event.endOfCombat, Subject.obj(oid));
            collectDelayed(g, DelayWhen.endOfCombat);
            startRound(g);
            break;
        case Step.main2:
            enterPhase(g, Phase.main2);
            startRound(g);
            break;
        case Step.duskTrigger:
            enterPhase(g, Phase.duskTrigger);
            collectScan(g, Event.turnEnd, Subject.player(g.active));
            collectScan(g, Event.yourTurnEnd, Subject.player(g.active));
            collectDelayed(g, DelayWhen.turnEnd);
            startRound(g);
            break;
        case Step.duskDiscard:
            enterPhase(g, Phase.duskDiscard);
            while (g.hand[g.active].length > g.cfg.handMax)
                discardOne(g, g.active);
            drain(g);
            g.next = Step.duskCleanup;
            break;
        case Step.duskCleanup:
            stepCleanup(g);
            drain(g);
            g.next = Step.turnAdvance;
            break;
        case Step.turnAdvance:
            g.turn++;
            g.active = 1 - g.active;
            g.touchDep(Dep.turn);
            if (g.turn > g.cfg.turnLimit)
                endMatch(g, true);
            else
                g.next = Step.turnStart;
            break;
        }
    }
}

private void stepDawn(Game g)
{
    enterPhase(g, Phase.dawn);
    g.cap[g.active] = cast(int) min(cast(long) g.cap[g.active] + 1, cast(long) g.cfg.maxCap);
    foreach (p; 0 .. 2)
    {
        g.ember[p] = g.cap[p];
        g.ev("EMBER", Pl(p), g.ember[p], g.cap[p]);
    }
    foreach (oid; g.field.dup)
        if (g.objs[oid].exhausted && g.ctl(oid) == g.active)
            setExhausted(g, oid, false);
    foreach (oid; g.field)
    {
        g.objs[oid].tenUsed = false;
        g.objs[oid].onceMask = 0;
    }
    g.touchDep(Dep.ready | Dep.ember);
    collectScan(g, Event.turnStart, Subject.player(g.active));
    collectScan(g, Event.yourTurnStart, Subject.player(g.active));
    collectDelayed(g, DelayWhen.yourNextTurnStart);
    drain(g);
}

private void stepCleanup(Game g)
{
    enterPhase(g, Phase.duskCleanup);
    foreach (oid; g.field)
    {
        g.objs[oid].wounds = 0;
        g.objs[oid].doomed = false;
        g.objs[oid].ward = 0;
    }
    g.shield[] = 0;
    size_t w = 0;
    foreach (r; g.recs)
    {
        if (r.aura)
            g.recs[w++] = r;
        else if (r.kind == RecKind.control)
        {
            foreach (a; r.affected)
                if (g.objs[a].zone == ZoneKind.field)
                    g.objs[a].since = g.turn;
        }
    }
    g.recs = g.recs[0 .. w];
    w = 0;
    foreach (d; g.delayed)
        if (d.when == DelayWhen.yourNextTurnStart)
            g.delayed[w++] = d;
    g.delayed = g.delayed[0 .. w];
    g.touch();
}

// ------------------------------------------------------------------- combat

/// Can `oid` be declared as an attacker (SPEC 19.2)?
bool canAttack(Game g, int oid)
{
    if (!g.onField(oid) || g.cardOf(oid).type != CardType.unit)
        return false;
    if (g.ctl(oid) != g.active || g.objs[oid].exhausted)
        return false;
    if (g.isSettling(oid) && !g.hasKw(oid, Keyword.vanguard))
        return false;
    return !g.hasKw(oid, Keyword.shackled);
}

/// Can `b` block attacker `a` (SPEC 19.4)?
bool canBlock(Game g, int b, int a)
{
    if (!g.onField(b) || g.cardOf(b).type != CardType.unit)
        return false;
    if (g.ctl(b) != 1 - g.active || g.objs[b].exhausted || g.hasKw(b, Keyword.siegework))
        return false;
    if (!g.onField(a) || !g.objs[a].attacking || g.cardOf(a).type != CardType.unit)
        return false;
    if (g.hasKw(a, Keyword.ghostwalk) && !(g.hasKw(b, Keyword.ghostwalk) || g.hasKw(b, Keyword.skyhook)))
        return false;
    return true;
}

private struct Assign
{
    int src;
    Target tgt;
    long amount;
}

private void assignFor(Game g, int u, ref Assign[] out_)
{
    immutable e = g.edgeOf(u);
    if (e <= 0)
        return;
    auto o = &g.objs[u];
    if (o.blocking)
    {
        if (g.onField(o.blockTarget))
            out_ ~= Assign(u, Target.object(o.blockTarget), e);
        return;
    }
    if (!o.attacking)
        return;
    immutable defender = 1 - g.active;
    if (!o.blocked)
    {
        out_ ~= Assign(u, Target.player(defender), e);
        return;
    }
    int[] list;
    foreach (b; o.blockers)
        if (g.onField(b) && g.objs[b].blocking && g.objs[b].blockTarget == u)
            list ~= b;
    if (list.empty)
        return;
    immutable venom = g.hasKw(u, Keyword.venom);
    long r = e;
    long[] amounts = new long[list.length];
    foreach (i, b; list)
    {
        long need = 1;
        if (!venom)
        {
            need = g.coreOf(b) - g.objs[b].wounds;
            if (need < 0)
                need = 0;
        }
        amounts[i] = min(r, need);
        r -= amounts[i];
    }
    Assign[] extra;
    if (r > 0)
    {
        if (g.hasKw(u, Keyword.pierce))
            extra ~= Assign(u, Target.player(defender), r);
        else
            amounts[$ - 1] += r;
    }
    foreach (i, b; list)
        if (amounts[i] > 0)
            out_ ~= Assign(u, Target.object(b), amounts[i]);
    out_ ~= extra;
}

/// Deal the combat damage of one sub-step (SPEC 19.5-19.6).
private void dealCombatDamage(Game g, bool riposteStep)
{
    ensureDerived(g);
    int[] dealers;
    foreach (oid; g.field)
    {
        if (!inCombat(g, oid))
            continue;
        if (riposteStep)
        {
            if (g.hasKw(oid, Keyword.riposte))
                dealers ~= oid;
        }
        else
        {
            bool done = false;
            foreach (r; g.riposters)
                if (r == oid)
                    done = true;
            if (!done)
                dealers ~= oid;
        }
    }
    if (riposteStep)
        g.riposters = dealers.dup;
    Assign[] pairs;
    foreach (d; dealers)
        assignFor(g, d, pairs);
    pairs.sort!((a, b) {
        if (a.src != b.src)
            return g.canonLess(a.src, b.src);
        if (a.tgt.kind != b.tgt.kind)
            return a.tgt.kind < b.tgt.kind;
        if (a.tgt.kind == 0)
            return a.tgt.id < b.tgt.id;
        if (a.tgt.id == b.tgt.id)
            return false;
        return g.canonLess(a.tgt.id, b.tgt.id);
    });
    foreach (p; pairs)
        dealDamage(g, p.src, p.tgt, p.amount);
}

// ----------------------------------------------------------- player actions

/// Called when a priority round ends with two passes on an empty Chain.
private void endRound(Game g)
{
    g.dec = DecKind.none;
    final switch (g.phase)
    {
    case Phase.main1:
        g.next = Step.clashAttack;
        break;
    case Phase.clashAttack:
        g.next = Step.clashBlock;
        break;
    case Phase.clashBlock:
        {
            ensureDerived(g);
            bool rip = false;
            foreach (oid; g.field)
                if (inCombat(g, oid) && g.hasKw(oid, Keyword.riposte))
                    rip = true;
            g.next = rip ? Step.clashRiposte : Step.clashDamage;
            g.riposters = null;
            break;
        }
    case Phase.clashRiposte:
        g.next = Step.clashDamage;
        break;
    case Phase.clashDamage:
        g.next = Step.clashEnd;
        break;
    case Phase.clashEnd:
        clearCombat(g);
        g.next = Step.main2;
        break;
    case Phase.main2:
        g.next = Step.duskTrigger;
        break;
    case Phase.duskTrigger:
        g.next = Step.duskDiscard;
        break;
    case Phase.dawn:
    case Phase.draw:
    case Phase.duskDiscard:
    case Phase.duskCleanup:
        break;
    }
}

/// Accepted `PASS` (SPEC 10.3).
void doPass(Game g, int p)
{
    g.ev("PASS", Pl(p));
    g.passCount++;
    if (g.passCount == 1)
        g.holder = 1 - g.holder;
    else if (g.chain.length)
    {
        g.passCount = 0;
        resolveTop(g);
        settle(g);
        if (g.over)
            return;
        g.holder = g.active;
    }
    else
    {
        endRound(g);
        advance(g);
    }
}

/// Accepted `CONCEDE`.
void doConcede(Game g, int p)
{
    recordLoss(g, p, Loss.concede);
    endMatch(g);
}

private void afterAction(Game g, int p)
{
    g.passCount = 0;
    g.holder = p;
    if (settle(g) && !g.over)
    {
        g.passCount = 0;
        g.holder = g.active;
    }
}

/// Printed cost of a card after `cheaper` reductions (SPEC 11.2 step 4).
long effectiveCost(Game g, int p, Card card)
{
    ensureDerived(g);
    long cost = card.cost;
    foreach (r; g.recs)
    {
        if (!r.aura || r.ctrl != p)
            continue;
        foreach (ref l; r.leaves)
        {
            if (!l.active || l.kind != StKind.cheaper)
                continue;
            bool all = true;
            foreach (f; l.cardFilters)
            {
                final switch (f.kind)
                {
                case FilterKind.type:
                    all = all && card.type == f.type;
                    break;
                case FilterKind.tag:
                    {
                        bool has = false;
                        foreach (t; card.tagIds)
                            has = has || t == f.tag;
                        all = all && has;
                        break;
                    }
                case FilterKind.cost:
                    all = all && compare(f.cmp, card.cost, f.n);
                    break;
                case FilterKind.kw:
                case FilterKind.noKw:
                case FilterKind.edge:
                case FilterKind.core:
                case FilterKind.wounded:
                case FilterKind.ready:
                case FilterKind.exhausted:
                case FilterKind.settling:
                case FilterKind.attacking:
                case FilterKind.blocking:
                case FilterKind.mine:
                case FilterKind.enemy:
                case FilterKind.other:
                case FilterKind.not:
                    all = false;
                    break;
                }
            }
            if (all)
                cost -= l.n;
        }
    }
    return cost < 0 ? 0 : cost;
}

/// Check target count and legality; returns an error kind or null.
private string checkTargets(Game g, TSpec[] specs, Target[] targets, int p, int src)
{
    if (targets.length != specs.length)
        return "bad-target-count";
    foreach (i, t; targets)
    {
        if (!targetLegal(g, specs[i], t, p, src, g.nextCid))
            return "illegal-target";
        foreach (j; 0 .. i)
            if (targets[j] == t)
                return "illegal-target";
    }
    return null;
}

/// `PLAY` (SPEC 11.2, 24). Returns the error kind, or null when accepted.
string doPlay(Game g, int p, long pos, Target[] targets)
{
    if (pos < 1 || pos > g.hand[p].length)
        return "no-such-card";
    immutable oid = g.hand[p][cast(size_t) pos - 1];
    auto card = g.cardOf(oid);
    immutable swift = card.type == CardType.rite && card.hasKeyword(Keyword.swift);
    if (!swift && !(g.active == p && (g.phase == Phase.main1 || g.phase == Phase.main2)
            && g.chain.empty))
        return "bad-timing";
    TSpec[] specs;
    if (card.type == CardType.rite)
        specs = card.abilities[0].targets;
    if (auto err = checkTargets(g, specs, targets, p, oid))
        return err;
    immutable cost = effectiveCost(g, p, card);
    if (g.ember[p] < cost)
        return "cannot-afford";

    auto e = new Entry;
    e.cid = g.nextCid++;
    e.kind = card.type == CardType.rite ? EntryKind.rite : card.type == CardType.unit
        ? EntryKind.unit : EntryKind.relic;
    e.ctrl = p;
    e.src = oid;
    e.abil = 0;
    e.targets = targets.dup;
    e.removed = new bool[targets.length];
    e.specs = specs;
    removeValue(g.hand[p], oid);
    g.objs[oid].zone = ZoneKind.chain;
    g.chain ~= e;
    g.touchDep(Dep.zones);
    g.ev("PLAY", Pl(p), Q(e.cid), O(oid), card.id, e.targets);
    if (cost > 0)
    {
        g.ember[p] -= cast(int) cost;
        g.touchDep(Dep.ember);
        g.ev("PAY", Pl(p), "ember", cost);
    }
    if (card.type == CardType.rite)
    {
        collectScan(g, Event.youPlayRite, Subject.obj(oid), p);
        collectScan(g, Event.enemyPlaysRite, Subject.obj(oid), p);
    }
    afterAction(g, p);
    return null;
}

private bool payable(Game g, int p, int oid, int idx, CostItem c)
{
    final switch (c.kind)
    {
    case CostKind.ember:
        return g.ember[p] >= c.n;
    case CostKind.spire:
        return true;
    case CostKind.discard:
        return g.hand[p].length >= c.n;
    case CostKind.exhaust:
        return g.onField(oid) && !g.objs[oid].exhausted
            && (!g.isSettling(oid) || g.hasKw(oid, Keyword.vanguard));
    case CostKind.sacself:
        return g.onField(oid);
    case CostKind.counters:
        return g.onField(oid) && g.objs[oid].counters >= c.n;
    case CostKind.once:
        return idx >= 64 || !(g.objs[oid].onceMask & (1UL << idx));
    }
}

/// Are all cost items of act ability `idx` of `oid` payable by `p`?
bool costsPayable(Game g, int p, int oid, int idx, Ability ab)
{
    foreach (c; ab.costs)
        if (!payable(g, p, oid, idx, c))
            return false;
    return true;
}

/// `ACT` (SPEC 11.3, 24). Returns the error kind, or null when accepted.
string doAct(Game g, int p, long oidL, long idx, Target[] targets)
{
    immutable oid = (oidL > 0 && oidL <= int.max) ? cast(int) oidL : 0;
    if (!g.onField(oid) || g.ctl(oid) != p)
        return "no-such-object";
    auto card = g.cardOf(oid);
    if (idx < 1 || idx > card.abilities.length || card.abilities[cast(size_t) idx - 1].kind != AbilKind.act
            || g.isStripped(oid))
        return "no-such-ability";
    auto ab = card.abilities[cast(size_t) idx - 1];
    if (auto err = checkTargets(g, ab.targets, targets, p, oid))
        return err;
    if (!costsPayable(g, p, oid, cast(int) idx, ab))
        return "cost-unpayable";

    auto e = new Entry;
    e.cid = g.nextCid++;
    e.kind = EntryKind.ability;
    e.ctrl = p;
    e.src = oid;
    e.abil = cast(int) idx;
    e.targets = targets.dup;
    e.removed = new bool[targets.length];
    e.specs = ab.targets;
    g.chain ~= e;
    g.ev("ACTIVATE", Pl(p), Q(e.cid), O(oid), idx, e.targets);
    foreach (c; ab.costs)
    {
        final switch (c.kind)
        {
        case CostKind.ember:
            g.ember[p] -= cast(int) c.n;
            g.touchDep(Dep.ember);
            if (c.n > 0)
                g.ev("PAY", Pl(p), "ember", c.n);
            break;
        case CostKind.spire:
            if (c.n > 0)
            {
                g.ev("PAY", Pl(p), "spire", c.n);
                changeSpire(g, p, -c.n);
            }
            break;
        case CostKind.discard:
            for (long i = 0; i < c.n; i++)
                discardOne(g, p);
            break;
        case CostKind.exhaust:
            setExhausted(g, oid, true);
            break;
        case CostKind.sacself:
            sacrificeObj(g, oid);
            break;
        case CostKind.counters:
            addCounters(g, oid, -c.n);
            break;
        case CostKind.once:
            if (idx < 64)
                g.objs[oid].onceMask |= 1UL << idx;
            break;
        }
    }
    afterAction(g, p);
    return null;
}

/// `ATTACK` (SPEC 19.1-19.2, 24). Returns the error kind, or null when accepted.
string doAttack(Game g, int p, long[] refs)
{
    foreach (i, a; refs)
        foreach (j; 0 .. i)
            if (refs[j] == a)
                return "duplicate-attacker";
    foreach (a; refs)
        if (a > int.max || !canAttack(g, cast(int) a))
            return "illegal-attacker";
    foreach (oid; g.field)
        if (canAttack(g, oid) && g.hasKw(oid, Keyword.relentless))
        {
            bool included = false;
            foreach (a; refs)
                included = included || a == oid;
            if (!included)
                return "missing-required-attacker";
        }
    int[] attackers;
    foreach (a; refs)
        attackers ~= cast(int) a;
    attackers.sort();
    foreach (oid; attackers)
    {
        g.objs[oid].attacking = true;
        g.touchDep(Dep.combat);
        if (!g.hasKw(oid, Keyword.vigil))
            setExhausted(g, oid, true);
        g.ev("ATTACK", O(oid));
    }
    foreach (oid; attackers)
        collectSelf(g, oid, Event.attacks, Subject.obj(oid));
    if (attackers.empty)
    {
        g.dec = DecKind.none;
        g.next = Step.main2;
        advance(g);
    }
    else
    {
        g.dec = DecKind.none;
        startRound(g);
    }
    return null;
}

/// One declared block.
struct BlockPair
{
    long blocker;
    long attacker;
}

/// `BLOCK` (SPEC 19.3-19.4, 24). Returns the error kind, or null when accepted.
string doBlock(Game g, int p, BlockPair[] pairs)
{
    foreach (i, a; pairs)
        foreach (j; 0 .. i)
            if (pairs[j].blocker == a.blocker)
                return "duplicate-blocker";
    foreach (a; pairs)
        if (a.blocker > int.max || a.attacker > int.max
                || !canBlock(g, cast(int) a.blocker, cast(int) a.attacker))
            return "illegal-blocker";
    // Provoke: every provoking attacker must be blocked if any unused unit could block it.
    foreach (a; g.field)
    {
        if (!g.objs[a].attacking || !g.hasKw(a, Keyword.provoke))
            continue;
        bool blocked = false;
        foreach (pr; pairs)
            blocked = blocked || pr.attacker == a;
        if (blocked)
            continue;
        foreach (b; g.field)
        {
            bool used = false;
            foreach (pr; pairs)
                used = used || pr.blocker == b;
            if (!used && canBlock(g, b, a))
                return "missing-required-block";
        }
    }
    auto sorted = pairs.dup;
    sorted.sort!((x, y) => x.blocker < y.blocker);
    foreach (pr; sorted)
    {
        immutable b = cast(int) pr.blocker;
        immutable a = cast(int) pr.attacker;
        g.objs[b].blocking = true;
        g.objs[b].blockTarget = a;
        g.objs[a].blockers ~= b;
        g.objs[a].blockers.sort!((x, y) => g.canonLess(x, y));
        g.objs[a].blocked = true;
        g.touchDep(Dep.combat);
        g.ev("BLOCK", O(b), O(a));
    }
    int[] attackers;
    foreach (oid; g.field)
        if (g.objs[oid].attacking)
            attackers ~= oid;
    attackers.sort();
    int[] unblocked;
    foreach (oid; attackers)
        if (g.objs[oid].blockers.empty)
        {
            unblocked ~= oid;
            g.ev("UNBLOCKED", O(oid));
        }
    foreach (pr; sorted)
        collectSelf(g, cast(int) pr.blocker, Event.blocks, Subject.obj(cast(int) pr.attacker));
    foreach (oid; attackers)
        if (g.objs[oid].blocked)
        {
            auto first = g.objs[oid].blockers.empty ? 0 : g.objs[oid].blockers[0];
            collectSelf(g, oid, Event.blocked, first ? Subject.obj(first) : Subject.init);
        }
    foreach (oid; unblocked)
        collectSelf(g, oid, Event.unblocked, Subject.obj(oid));
    g.dec = DecKind.none;
    startRound(g);
    return null;
}

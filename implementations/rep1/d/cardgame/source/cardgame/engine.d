/**
 * The resumable game engine: turn structure, priority rounds and combat
 * (SPEC.md sections 8-10 and 19). Rules processing runs on a fiber that
 * suspends at every decision point and resumes with the next player action.
 */
module cardgame.engine;

import core.thread : Fiber;
import std.algorithm : min;
import cardgame.chain;
import cardgame.combat;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.procs;
import cardgame.select;
import cardgame.settle;
import cardgame.triggers;

/// A validated player action handed to the engine.
struct Action
{
    enum Kind : ubyte { pass, play, act, attack, block }
    Kind kind;
    Player player;
    size_t pos;             // play: 1-based hand position
    long cost;              // play: Ember cost
    Target[] targets;       // play / act
    Obj obj;                // act: source object
    Ability ability;        // act
    Obj[] list;             // attack: attackers; block: blockers
    Obj[] list2;            // block: the attackers they block
}

/// Drives a `Game` from setup to the end of the match.
final class Engine
{
    Game g;
    private Fiber fiber;
    private Action next;

    this(Game g)
    {
        this.g = g;
        fiber = new Fiber(&run, 32 * 1024 * 1024);
    }

    /// Run setup and the engine up to the first decision point.
    void start() { fiber.call(); }

    /// Hand a validated action to the engine and run to the next decision point.
    void submit(Action a)
    {
        next = a;
        fiber.call();
    }

    /// Whether rules processing has finished (the match ended).
    bool finished() const { return g.ended; }

    private void run()
    {
        try
            playMatch();
        catch (MatchEnded)
        {
        }
    }

    private Action wait(Player p, Decision d)
    {
        g.decisionPlayer = p;
        g.decision = d;
        Fiber.yield();
        return next;
    }

    // ------------------------------------------------------------ match

    private void playMatch()
    {
        immutable first = g.cfg.first;
        g.emit("GAME-START", Game.r(first));
        if (g.cfg.shuffle)
        {
            foreach (p; [Player.A, Player.B])
            {
                g.rng.shuffle(g.pl[p].vault.items);
                g.emit("SHUFFLE", Game.r(p));
            }
        }
        g.quiet = true;
        foreach (p; [first, opponent(first)])
            drawCards(g, p, g.cfg.opening);
        g.quiet = false;
        settle(g);

        for (;;)
        {
            g.emit("TURN", g.turn, Game.r(g.active));
            dawn();
            drawStep();
            enter("main1");
            priorityRound();
            clash();
            enter("main2");
            priorityRound();
            dusk();
            ++g.turn;
            g.active = opponent(g.active);
            g.dirty = true;
            if (g.turn > g.cfg.turnLimit) finish(g, "draw", "turn-limit");
        }
    }

    private void enter(string phase)
    {
        g.phase = phase;
        g.emit("PHASE", phase);
    }

    // ------------------------------------------------------------ turn steps

    private void dawn()
    {
        enter("dawn");
        auto a = g.active;
        g.pl[a].cap = min(g.pl[a].cap + 1, cast(long) g.cfg.maxCap);
        foreach (p; [Player.A, Player.B])
        {
            g.pl[p].ember = g.pl[p].cap;
            g.emit("EMBER", Game.r(p), g.pl[p].ember, g.pl[p].cap);
        }
        g.dirty = true;
        ensureDerived(g);
        foreach (o; g.field.dup)
            if (o.ctrl == a && o.exhausted) setExhausted(g, o, false);
        foreach (o; g.field)
        {
            o.tenacityUsed = false;
            o.usedOnce = null;
        }
        g.dirty = true;
        ensureDerived(g);
        foreach (o; g.field)
        {
            collectFrom(g, o, Event.turnStart, Subject.ofPlayer(a));
            if (o.ctrl == a) collectFrom(g, o, Event.yourTurnStart, Subject.ofPlayer(a));
        }
        fireDelayed(When.yourNextTurnStart);
        drain(g);
    }

    private void fireDelayed(When w)
    {
        Delayed[] keep;
        foreach (d; g.delayed)
        {
            immutable fire = d.when == w && (w != When.yourNextTurnStart || d.ctrl == g.active);
            if (fire) g.pending ~= Pending(d.src, 0, d.ctrl, d.ts, Subject.init, d);
            else keep ~= d;
        }
        g.delayed = keep;
    }

    private void drawStep()
    {
        enter("draw");
        if (g.turn != 1) drawCards(g, g.active, 1);
        drain(g);
    }

    private void dusk()
    {
        enter("dusk-trigger");
        ensureDerived(g);
        foreach (o; g.field)
        {
            collectFrom(g, o, Event.turnEnd, Subject.ofPlayer(g.active));
            if (o.ctrl == g.active) collectFrom(g, o, Event.yourTurnEnd, Subject.ofPlayer(g.active));
        }
        fireDelayed(When.turnEnd);
        priorityRound();

        enter("dusk-discard");
        while (g.pl[g.active].hand.length > g.cfg.handMax) discardTop(g, g.active);
        drain(g);

        enter("dusk-cleanup");
        foreach (o; g.field)
        {
            o.wounds = 0;
            o.doomed = false;
            o.ward = 0;
        }
        g.pl[0].shield = 0;
        g.pl[1].shield = 0;
        Record[] keep;
        foreach (r; g.records)
        {
            if (r.aura) { keep ~= r; continue; }
            if (r.kind == RecKind.control)
                foreach (oid; r.affected)
                {
                    auto o = g.objs[oid];
                    if (o.zone == Zone.field) o.since = g.turn;
                }
        }
        g.records = keep;
        Delayed[] dkeep;
        foreach (d; g.delayed) if (d.when == When.yourNextTurnStart) dkeep ~= d;
        g.delayed = dkeep;
        g.dirty = true;
        drain(g);
    }

    // ------------------------------------------------------------ priority

    private void priorityRound()
    {
        int passes = 0;
        settle(g);
        auto holder = g.active;
        for (;;)
        {
            auto a = wait(holder, Decision.priority);
            final switch (a.kind)
            {
            case Action.Kind.pass:
                g.emit("PASS", Game.r(holder));
                ++passes;
                if (passes == 1) holder = opponent(holder);
                else if (g.chain.length > 0)
                {
                    passes = 0;
                    resolveTop(g);
                    settle(g);
                    holder = g.active;
                }
                else return;
                break;
            case Action.Kind.play:
                doPlay(g, a.player, a.pos, a.targets, a.cost);
                passes = 0;
                holder = a.player;
                if (settle(g)) { passes = 0; holder = g.active; }
                break;
            case Action.Kind.act:
                doAct(g, a.player, a.obj, a.ability, a.targets);
                passes = 0;
                holder = a.player;
                if (settle(g)) { passes = 0; holder = g.active; }
                break;
            case Action.Kind.attack:
            case Action.Kind.block:
                assert(0, "attack/block outside their decisions");
            }
        }
    }

    // ------------------------------------------------------------ combat

    private void clash()
    {
        enter("clash-attack");
        settle(g);
        auto a = wait(g.active, Decision.attackers);
        if (a.list.length == 0) return;
        declareAttackers(g, a.list);
        priorityRound();

        enter("clash-block");
        settle(g);
        auto b = wait(opponent(g.active), Decision.blockers);
        declareBlockers(g, b.list, b.list2);
        priorityRound();

        bool[int] rip;
        Obj[] ripSet;
        ensureDerived(g);
        foreach (o; inCombat(g)) if (o.has(Kw.riposte)) { ripSet ~= o; rip[o.oid] = true; }
        if (ripSet.length > 0)
        {
            enter("clash-riposte");
            dealCombatDamage(g, ripSet);
            priorityRound();
        }

        enter("clash-damage");
        Obj[] rest;
        foreach (o; inCombat(g)) if (o.oid !in rip) rest ~= o;
        dealCombatDamage(g, rest);
        priorityRound();

        enter("clash-end");
        ensureDerived(g);
        foreach (o; inCombat(g)) collectFrom(g, o, Event.endOfCombat, Subject.ofObj(o.oid));
        fireDelayed(When.endOfCombat);
        priorityRound();
        foreach (o; g.field)
        {
            o.attacking = o.blocking = o.blockedFlag = false;
            o.blockers = null;
            o.blockedAttacker = null;
        }
        g.dirty = true;
    }
}

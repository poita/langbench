/**
 * State checks, `settle` and `drain` (SPEC.md sections 10.5, 10.6, 18) and
 * match ending (section 20).
 */
module cardgame.settle;

import cardgame.chain;
import cardgame.game;
import cardgame.layers;
import cardgame.model;
import cardgame.procs;
import cardgame.select;
import cardgame.triggers;

/// End the match according to the recorded losses; never returns normally.
void endMatch(Game g)
{
    foreach (p; [Player.A, Player.B])
        if (g.loss[p] !is null) g.emit("LOSE", Game.r(p), g.loss[p]);
    string winner, reason;
    if (g.loss[0] !is null && g.loss[1] !is null) { winner = "draw"; reason = g.loss[0]; }
    else if (g.loss[0] !is null) { winner = "B"; reason = g.loss[0]; }
    else { winner = "A"; reason = g.loss[1]; }
    finish(g, winner, reason);
}

/// Record the final result and unwind.
void finish(Game g, string winner, string reason)
{
    g.emit("RESULT", winner, reason);
    g.ended = true;
    g.resultWinner = winner;
    g.resultReason = reason;
    g.decision = Decision.over;
    throw new MatchEnded;
}

/// One run of the state checks (18). Returns whether it acted.
bool stateChecks(Game g)
{
    foreach (p; [Player.A, Player.B])
        if (g.pl[p].spire <= 0 && g.loss[p] is null) g.loss[p] = "spire";
    if (g.loss[0] !is null || g.loss[1] !is null) endMatch(g);

    ensureDerived(g);
    Obj[] doomed;
    foreach (o; g.field)
        if (o.isUnit && (o.core <= o.wounds || o.doomed)) doomed ~= o;
    foreach (o; doomed) destroyObj(g, o);
    return doomed.length > 0;
}

/// Run state checks and trigger pushes until nothing more happens (10.5).
bool settle(Game g)
{
    bool acted;
    for (;;)
    {
        immutable a = stateChecks(g);
        immutable b = pushTriggers(g);
        acted = acted || a || b;
        if (!a && !b) break;
    }
    return acted;
}

/// Empty the Chain without player input (10.6).
void drain(Game g)
{
    for (;;)
    {
        settle(g);
        if (g.chain.length == 0) break;
        resolveTop(g);
    }
}

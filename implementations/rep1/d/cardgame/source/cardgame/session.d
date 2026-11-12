/**
 * Runs a whole match file: setup, the script, error reporting and trace
 * blocks. This is the library's main entry point (`runMatch`).
 */
module cardgame.session;

import std.conv : to;
import cardgame.chain;
import cardgame.combat;
import cardgame.database;
import cardgame.dump;
import cardgame.engine;
import cardgame.game;
import cardgame.layers;
import cardgame.matchfile;
import cardgame.model;
import cardgame.procs;
import cardgame.rng;
import cardgame.settle;

/// Callback used to read the card database named by `CARDS`; may throw.
alias FileReader = string delegate(string path);

/// Build the initial game state from a validated setup (SPEC.md section 8, steps 4-6).
Game buildGame(Database db, in MatchSetup m)
{
    auto g = new Game(db, m.cfg);
    g.active = m.cfg.first;
    foreach (p; [Player.A, Player.B])
    {
        g.pl[p].spire = m.cfg.spire;
        g.pl[p].cap = m.cfg.startCap[p];
    }
    Obj[] toField;
    foreach (p; [Player.A, Player.B])
        foreach (z; [SetupZone.deck, SetupZone.hand, SetupZone.field, SetupZone.ash, SetupZone.rift])
            foreach (e; m.zones[p][z])
                foreach (i; 0 .. e.count)
                {
                    auto o = g.createObj(db.find(e.cardId), p);
                    final switch (z)
                    {
                    case SetupZone.deck: g.place(o, Zone.vault); break;
                    case SetupZone.hand: g.place(o, Zone.hand); break;
                    case SetupZone.field: toField ~= o; break;
                    case SetupZone.ash: g.place(o, Zone.ash); break;
                    case SetupZone.rift: g.place(o, Zone.rift); break;
                    }
                }
    foreach (o; toField)
    {
        placeOnField(g, o, o.owner);
        o.since = 0;
    }
    g.rng = Rng(m.cfg.seed);
    return g;
}

/// Run a match file to completion and return everything it prints.
string runMatch(string input, FileReader readFile)
{
    auto lines = splitLines(input);
    MatchSetup setup;
    try
        setup = parseSetup(lines);
    catch (SetupException)
        return "FATAL bad-setup\n";
    Database db;
    try
        db = parseDatabase(readFile(setup.cardsPath));
    catch (Exception)
        return "FATAL bad-database\n";
    foreach (p; [Player.A, Player.B])
        foreach (z; setup.zones[p])
            foreach (e; z)
                if (db.find(e.cardId) is null) return "FATAL unknown-card\n";

    auto g = buildGame(db, setup);
    auto engine = new Engine(g);
    engine.start();
    foreach (idx; setup.startLine + 1 .. lines.length)
    {
        if (isCommentLine(lines[idx])) continue;
        processLine(g, engine, lines[idx], idx + 1);
    }
    if (!g.ended) g.emit("RESULT", "pending", "none");
    return g.output;
}

private void err(Game g, size_t lineNo, string kind)
{
    g.rawLine("ERR " ~ lineNo.to!string ~ " " ~ kind);
}

private void trace(Game g)
{
    final switch (g.cfg.trace)
    {
    case Settings.Trace.none: break;
    case Settings.Trace.legal: g.rawLine(legalBlock(g)); break;
    case Settings.Trace.state: g.rawLine(dumpState(g)); break;
    }
}

/// Process one script line against the running engine.
void processLine(Game g, Engine engine, string line, size_t lineNo)
{
    auto c = parseCommand(line);
    final switch (c.kind)
    {
    case Command.Kind.bad: err(g, lineNo, "bad-syntax"); return;
    case Command.Kind.dump: g.rawLine(dumpState(g)); return;
    case Command.Kind.legal: g.rawLine(legalBlock(g)); return;
    case Command.Kind.vault: g.rawLine(vaultBlock(g)); return;
    case Command.Kind.card: g.rawLine(cardBlock(g.db, c.word)); return;
    case Command.Kind.pass, Command.Kind.concede, Command.Kind.play, Command.Kind.act,
         Command.Kind.attack, Command.Kind.block:
        break;
    }
    if (g.ended) { err(g, lineNo, "game-over"); return; }
    if (c.player != g.decisionPlayer) { err(g, lineNo, "not-your-turn"); return; }
    immutable need = c.kind == Command.Kind.attack ? Decision.attackers
        : c.kind == Command.Kind.block ? Decision.blockers : Decision.priority;
    if (c.kind != Command.Kind.concede && g.decision != need)
    {
        err(g, lineNo, "wrong-decision");
        return;
    }

    Action a;
    a.player = c.player;
    string e;
    final switch (c.kind)
    {
    case Command.Kind.concede:
        if (g.loss[c.player] is null) g.loss[c.player] = "concede";
        try endMatch(g);
        catch (MatchEnded) {}
        trace(g);
        return;
    case Command.Kind.pass:
        a.kind = Action.Kind.pass;
        break;
    case Command.Kind.play:
        a.kind = Action.Kind.play;
        e = checkPlay(g, c.player, c.n1, c.toks, a.targets, a.cost);
        a.pos = cast(size_t) c.n1;
        break;
    case Command.Kind.act:
        a.kind = Action.Kind.act;
        e = checkAct(g, c.player, c.n1, c.n2, c.toks, a.targets, a.ability);
        if (e is null) a.obj = g.obj(cast(long) c.n1);
        break;
    case Command.Kind.attack:
        a.kind = Action.Kind.attack;
        e = checkAttack(g, c.ids, a.list);
        break;
    case Command.Kind.block:
        a.kind = Action.Kind.block;
        e = checkBlock(g, c.ids, c.ids2, a.list, a.list2);
        break;
    case Command.Kind.bad, Command.Kind.dump, Command.Kind.legal, Command.Kind.vault, Command.Kind.card:
        assert(0);
    }
    if (e !is null) { err(g, lineNo, e); return; }
    engine.submit(a);
    trace(g);
}

version (unittest)
{
    import std.functional : toDelegate;

    private enum miniDb = `
        (card AAA-001 (name "Runner") (type unit) (cost 1) (body 2 1) (keywords vanguard))
        (card AAA-002 (name "Bolt") (type rite) (cost 1) (keywords swift)
          (resolve (targets (any)) (damage 2 (t 1))))`;

    private string reader(string path)
    {
        if (path == "mem:db") return miniDb;
        if (path == "mem:bad") return "(card";
        throw new Exception("unreadable");
    }

    unittest // fatal setup and database errors
    {
        assert(runMatch("SEED 1\nSTART\n", toDelegate(&reader)) == "FATAL bad-setup\n");
        assert(runMatch("CARDS mem:db\nSEED 1\nSPIRE 0\nSTART\n", toDelegate(&reader)) == "FATAL bad-setup\n");
        assert(runMatch("CARDS mem:bad\nSEED 1\nSTART\n", toDelegate(&reader)) == "FATAL bad-database\n");
        assert(runMatch("CARDS mem:missing\nSEED 1\nSTART\n", toDelegate(&reader)) == "FATAL bad-database\n");
        assert(runMatch("CARDS mem:db\nSEED 1\nDECK A ZZZ-999\nSTART\n", toDelegate(&reader)) == "FATAL unknown-card\n");
    }

    unittest // a bolt to the face ends a two-Spire match
    {
        import std.algorithm : canFind;
        auto out_ = runMatch("CARDS mem:db\nSEED 1\nSPIRE 2\nOPENING 0\nSHUFFLE off\n"
            ~ "DECK A AAA-001\nDECK B AAA-001\nHAND A AAA-002\nSTART\n"
            ~ "A PLAY 1 B\nA PASS\nB PASS\nA PASS\n", toDelegate(&reader));
        assert(out_.canFind("LOSE B spire\n"));
        assert(out_.canFind("RESULT A spire\nERR 13 game-over"));
    }

    unittest // errors do not consume sequence numbers
    {
        import std.algorithm : canFind;
        auto out_ = runMatch("CARDS mem:db\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\nA BOGUS\nB PASS\nA PASS\n", toDelegate(&reader));
        assert(out_.canFind("ERR 6 bad-syntax\nERR 7 not-your-turn\n8 PASS A"));
    }
}

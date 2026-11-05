/// Scenario tests for the rules engine, mirroring the worked examples of SPEC 26.
module tests.engine_test;

import std.algorithm : canFind;
import std.array : join;

import tests.util;

private string[] header(string[] extra = null)
{
    return quietSetup ~ extra;
}

unittest
{
    // SPEC 26.4: a rite kills a unit.
    auto got = runMatch(header(["DECK A TST-001", "DECK B TST-001", "HAND A TST-002", "FIELD B TST-003",
        "START", "A PLAY 1 #4", "A PASS", "B PASS", "A PASS", "B PASS"]));
    assert(got == "1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 TST-002 #4
9 PAY A ember 1
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 #4 2
14 SPENT #2 TST-002
15 DESTROY #4 TST-003
16 PASS A
17 PASS B
18 PHASE clash-attack
19 RESULT pending none
");
}

unittest
{
    // SPEC 26.5: riposte combat deals damage in its own sub-step.
    auto got = runMatch(header(["DECK A TST-001", "DECK B TST-001", "FIELD A TST-004", "FIELD B TST-003",
        "START", "A PASS", "B PASS", "A ATTACK #2", "A PASS", "B PASS", "B BLOCK #4:#2",
        "A PASS", "B PASS", "A PASS", "B PASS"]));
    assert(got.canFind("11 EXHAUST #2\n12 ATTACK #2\n"));
    assert(got.canFind("15 PHASE clash-block\n16 BLOCK #4 #2\n"));
    assert(got.canFind("19 PHASE clash-riposte\n20 DAMAGE #2 #4 2\n21 DESTROY #4 TST-003\n"));
    assert(got.canFind("24 PHASE clash-damage\n25 RESULT pending none\n"));
}

unittest
{
    // SPEC 26.8: tenacity replaces the first destruction only.
    auto got = runMatch(header(["CAP A 3", "DECK A TST-001", "DECK B TST-001", "HAND A TST-007 TST-007",
        "FIELD B TST-006", "START", "A PLAY 1 #5", "A PASS", "B PASS", "A PLAY 1 #5", "A PASS", "B PASS", "DUMP"]));
    assert(got.canFind("13 DAMAGE #2 #5 3\n14 SPENT #2 TST-007\n15 TENACITY #5\n"));
    assert(got.canFind("21 DAMAGE #3 #5 3\n22 SPENT #3 TST-007\n23 DESTROY #5 TST-006\n"));
    assert(got.canFind("ash B 1 #5 TST-006\n"));
}

unittest
{
    // SPEC 26.9: bouncing a rite's target makes it fizzle.
    auto got = runMatch(header(["CAP A 1", "CAP B 1", "DECK A TST-001", "DECK B TST-001", "HAND A TST-007",
        "HAND B TST-008", "FIELD B TST-003", "START",
        "A PLAY 1 #5", "A PASS", "B PLAY 1 #5", "B PASS", "A PASS", "A PASS", "B PASS", "DUMP"]));
    assert(got.canFind("16 BOUNCE #5 TST-003\n17 SPENT #4 TST-008\n"));
    assert(got.canFind("20 RESOLVE ~1\n21 FIZZLE ~1\n22 SPENT #2 TST-007\n"));
    assert(got.canFind("hand B 1 #5 TST-003\n"));
}

unittest
{
    // SPEC 26.13: damage to a player's Spire ends the match; later actions are game-over.
    auto got = runMatch(["CARDS db", "SEED 1", "SPIRE 2", "OPENING 0", "SHUFFLE off", "DECK A TST-001",
        "DECK B TST-001", "HAND A TST-002", "START", "A PLAY 1 B", "A PASS", "B PASS", "A PASS"]);
    assert(got.canFind("13 DAMAGE #2 B 2\n14 SPIRE B -2 0\n15 SPENT #2 TST-002\n16 LOSE B spire\n17 RESULT A spire\n"));
    assert(got.canFind("ERR 13 game-over"));
}

unittest
{
    // SPEC 26.6: triggers are ordered by controller, then timestamp; first in order resolves first.
    auto got = runMatch(header(["CAP A 3", "DECK A TST-001", "DECK B TST-001", "HAND A TST-011",
        "FIELD A TST-009 TST-009 TST-003", "FIELD B TST-009", "START",
        "A PLAY 1 #5", "A PASS", "B PASS"]));
    // #3 and #4 (A's TST-009) listen for ally-dies of #5; B's #7 only listens for its own allies.
    assert(got.canFind("TRIGGER A ~2 #3 1\n16 TRIGGER A ~3 #4 1\n"));
}

unittest
{
    // SPEC 26.7 flavour: an aura relic pumps its controller's units, and the DUMP shows the record.
    auto got = runMatch(header(["FIELD A TST-005 TST-003", "FIELD B TST-003", "START", "DUMP"]));
    assert(got.canFind("field A #2 TST-003 2/2 w0 c0 ready - kw -\n"));
    assert(got.canFind("field A #1 TST-005 -/- w0 c0 ready - kw -\n"));
    assert(got.canFind("field B #3 TST-003 1/1 w0 c0 ready - kw -\n"));
    assert(got.canFind("effect 1 ts2 A aura modify 1 1 on #2\n"));
}

unittest
{
    // SPEC 26.10: LEGAL at priority, attackers and blockers.
    auto got = runMatch(header(["CAP A 2", "DECK A TST-001", "DECK B TST-001", "HAND A TST-002 TST-001",
        "FIELD A TST-003", "FIELD B TST-003", "START", "LEGAL", "A PASS", "B PASS", "LEGAL",
        "A ATTACK #4", "A PASS", "B PASS", "LEGAL"]));
    assert(got.canFind("LEGAL BEGIN A priority\nPASS\nPLAY 1 TST-002 A\nPLAY 1 TST-002 B\n"
            ~ "PLAY 1 TST-002 #4\nPLAY 1 TST-002 #6\nPLAY 2 TST-001\nLEGAL END\n"));
    assert(got.canFind("LEGAL BEGIN A attackers\nCANATTACK #4\nLEGAL END\n"));
    assert(got.canFind("LEGAL BEGIN B blockers\nCANBLOCK #6 #4\nLEGAL END\n"));
}

unittest
{
    // Concession ends the match immediately; TRACE state prints the finished state.
    auto got = runMatch(["CARDS db", "SEED 1", "OPENING 0", "SHUFFLE off", "TRACE state", "START", "B CONCEDE"]);
    assert(got.canFind("not-your-turn"));
    got = runMatch(["CARDS db", "SEED 1", "OPENING 0", "SHUFFLE off", "TRACE state", "START", "A CONCEDE"]);
    assert(got.canFind("8 LOSE A concede\n9 RESULT B concede\nSTATE BEGIN\n"));
    assert(got.canFind("decision - over\nresult B concede\n"));
}

unittest
{
    // The turn limit ends the game as a draw after the increment.
    auto lines = ["CARDS db", "SEED 1", "OPENING 0", "SHUFFLE off", "TURNLIMIT 1", "DECK A TST-001*5", "DECK B TST-001*5",
        "START", "A PASS", "B PASS", "A ATTACK", "A PASS", "B PASS", "A PASS", "B PASS", "DUMP"];
    auto got = runMatch(lines);
    assert(got.canFind("RESULT draw turn-limit\n"));
    assert(got.canFind("turn 2 active B phase dusk-cleanup decision - over\nresult draw turn-limit\n"));
}

unittest
{
    // Activated abilities: costs are paid in order, and an unpayable cost is an error.
    auto got = runMatch(header(["CAP A 3", "DECK A TST-001", "DECK B TST-001", "FIELD A TST-010", "FIELD B TST-003",
        "START", "A ACT #2 2 #4", "A ACT #2 1 #4", "A ACT #2 2 #4", "A PASS", "B PASS", "DUMP"]));
    assert(got.canFind("8 ACTIVATE A ~1 #2 2 #4\n9 EXHAUST #2\n10 PAY A spire 2\n11 SPIRE A -2 8\n"));
    assert(got.canFind("ERR 13 no-such-ability\nERR 14 cost-unpayable\n"));
    // Paying the Spire cost triggers Harvester's own spire-loss ability, which sits above the activation.
    assert(got.canFind("12 TRIGGER A ~2 #2 1\n"));
    assert(got.canFind("chain 1 ~1 A ability #2 2 #4\n"));
    assert(got.canFind("field A #2 TST-010 3/3 w0 c1 exhausted - kw -\n"));
}

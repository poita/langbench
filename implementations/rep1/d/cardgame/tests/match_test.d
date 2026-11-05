/// Unit tests for match-file handling: setup errors, directives and script errors.
module tests.match_test;

import std.algorithm : startsWith;
import std.string : lineSplitter;
import std.array : array;

import cardgame.match : simulate;

import tests.util;

unittest
{
    // Setup violations (SPEC 8 step 1).
    assert(runMatch(["SEED 1", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "SEED 2", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "BOGUS 3", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED -1", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 18446744073709551616", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "SPIRE 0", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "HANDMAX 101", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "TRACE all", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "CAP A 1", "CAP A 2", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "DECK A TST-001*1001", "START"]) == "FATAL bad-setup\n");
    assert(runMatch(["CARDS db", "SEED 1", "START now"]) == "FATAL bad-setup\n");
    // Leading zeros are fine.
    assert(runMatch(["CARDS db", "SEED 0001", "SPIRE 010", "OPENING 0", "START"]).startsWith("1 GAME-START A\n"));
}

unittest
{
    // Database and card-id failures.
    assert(runMatch(["CARDS missing", "SEED 1", "START"]) == "FATAL bad-database\n");
    assert(runMatch(["CARDS db", "SEED 1", "START"], "(card nonsense") == "FATAL bad-database\n");
    assert(runMatch(["CARDS db", "SEED 1", "DECK A ZZZ-999", "START"]) == "FATAL unknown-card\n");
    assert(runMatch(["CARDS db", "SEED 1", "FIELD B tst-001", "START"]) == "FATAL unknown-card\n");
}

unittest
{
    // SPEC 26.1 in miniature: CARD output and the pending result.
    auto out_ = runMatch(quietSetup ~ ["START", "CARD TST-002", "CARD TST-010", "CARD ZZZ-999"]);
    assert(out_ == "1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
CARD BEGIN TST-002
name Bolt
type rite
cost 1
tags test
keywords swift
ability 1 resolve (targets (any)) (damage 2 (t 1))
CARD END
CARD BEGIN TST-010
name Harvester
type unit
cost 3
body 2/2
tags test,undead
keywords -
ability 1 on spire-loss - (counters 1 self)
ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))
CARD END
CARD BEGIN ZZZ-999
unknown
CARD END
8 RESULT pending none
");
}

unittest
{
    // SPEC 26.11: syntax errors, turn errors and precedence; ERR lines use input line numbers.
    auto out_ = runMatch(quietSetup ~ [
        "DECK A TST-001", "DECK B TST-001", "HAND A TST-002 TST-007", "START",
        "X PASS", "B PASS", "A BLOCK", "A PLAY 5", "A PLAY 1", "A PLAY 1 #99",
        "A PLAY 2 #99", "A PLAY 1 A", "DUMP x", "CARD", "A PASS 1",
    ]);
    auto lines = out_.lineSplitter.array;
    assert(lines.length >= 8);
    import std.algorithm : canFind;
    foreach (want; ["ERR 10 bad-syntax", "ERR 11 not-your-turn", "ERR 12 wrong-decision",
            "ERR 13 no-such-card", "ERR 14 bad-target-count", "ERR 15 illegal-target",
            "ERR 16 illegal-target", "ERR 18 bad-syntax", "ERR 19 bad-syntax", "ERR 20 bad-syntax"])
        assert(lines.canFind(want), want);
    assert(out_.canFind("PLAY A ~1 #2 TST-002 A"));
    assert(out_.canFind("PAY A ember 1"));
}

unittest
{
    // Comments and blank lines are ignored but still counted in ERR line numbers.
    auto out_ = runMatch(quietSetup ~ ["START", "# comment", "", "   ", "A FLY"]);
    assert(out_.canFind_("ERR 10 bad-syntax"));
}

private bool canFind_(string hay, string needle)
{
    import std.algorithm : canFind;

    return hay.canFind(needle);
}

unittest
{
    // SPEC 26.12 in miniature: shuffling and the VAULT block with seed 7.
    auto out_ = runMatch(["CARDS db", "SEED 7", "SPIRE 10", "OPENING 0",
        "DECK A TST-001 TST-002 TST-003 TST-004 TST-005 TST-006 TST-007 TST-008", "START", "VAULT"]);
    assert(out_.canFind_("2 SHUFFLE A\n3 SHUFFLE B\n4 TURN 1 A\n"));
    assert(out_.canFind_("vault A 1 #6 TST-006\nvault A 2 #8 TST-008\nvault A 3 #5 TST-005\n"
            ~ "vault A 4 #2 TST-002\nvault A 5 #4 TST-004\nvault A 6 #1 TST-001\n"
            ~ "vault A 7 #3 TST-003\nvault A 8 #7 TST-007\nVAULT END\n"));
}

unittest
{
    // Opening hands that exhaust a Vault lose immediately (SPEC 8 steps 8-9).
    auto out_ = runMatch(["CARDS db", "SEED 1", "OPENING 2", "SHUFFLE off", "DECK A TST-001", "DECK B TST-001*2", "START",
        "A PASS", "DUMP"]);
    assert(out_.canFind_("DRAW-EMPTY A"));
    assert(out_.canFind_("LOSE A vault\n"));
    assert(out_.canFind_("RESULT B vault\n"));
    assert(out_.canFind_("ERR 8 game-over"));
    assert(out_.canFind_("turn 1 active A phase dawn decision - over\nresult B vault\n"));
}

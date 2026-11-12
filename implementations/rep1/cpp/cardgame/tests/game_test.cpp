// End-to-end rules tests: a tiny inline database, a match file, and the exact log.
#include <gtest/gtest.h>

#include <fstream>
#include <sstream>

#include "spiremark/session.hpp"

namespace {

const char* kDb = R"(
(card TOK-001 (name "Mote") (type unit) (cost 0) (body 1 1))
(card TST-001 (name "Bolt") (type rite) (cost 1) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card TST-002 (name "Duelist") (type unit) (cost 2) (body 2 1) (keywords riposte vanguard))
(card TST-003 (name "Armour") (type unit) (cost 2) (body 0 3) (keywords (plating 1) tenacity))
(card TST-004 (name "Undo") (type rite) (cost 1) (keywords swift)
  (resolve (targets (chained)) (negate (t 1))))
(card TST-005 (name "Mirror") (type unit) (cost 1) (body 1 1)
  (aura (modify 1 1 (units yours (other)))))
(card TST-006 (name "Herald") (type unit) (cost 1) (body 1 1)
  (on arrive (summon TOK-001 2 you)))
(card TST-008 (name "Immortal") (type unit) (cost 1) (body 1 1) (keywords tenacity))
(card TST-007 (name "Doomer") (type rite) (cost 1)
  (resolve (targets (unit)) (strip (t 1))))
)";

std::string run(const std::string& setup_and_script) {
    std::string path = testing::TempDir() + "spiremark_test_cards.spire";
    {
        std::ofstream f(path);
        f << kDb;
    }
    std::ostringstream out;
    spiremark::run_match("CARDS " + path + "\n" + setup_and_script, out);
    return out.str();
}

bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

}  // namespace

TEST(Game, SetupAndFirstDecision) {
    std::string out = run("SEED 1\nOPENING 0\nSHUFFLE off\nSTART\n");
    EXPECT_EQ(out,
              "1 GAME-START A\n2 TURN 1 A\n3 PHASE dawn\n4 EMBER A 1 1\n5 EMBER B 0 0\n"
              "6 PHASE draw\n7 PHASE main1\n8 RESULT pending none\n");
}

TEST(Game, FatalErrors) {
    EXPECT_EQ(run("SEED 1\nSTART\nDUMP\n").substr(0, 0), "");
    std::ostringstream o1;
    spiremark::run_match("SEED 1\nSTART\n", o1);
    EXPECT_EQ(o1.str(), "FATAL bad-setup\n");
    std::ostringstream o2;
    spiremark::run_match("CARDS /does/not/exist\nSEED 1\nSTART\n", o2);
    EXPECT_EQ(o2.str(), "FATAL bad-database\n");
    EXPECT_EQ(run("SEED 1\nDECK A NOP-001\nSTART\n"), "FATAL unknown-card\n");
}

TEST(Game, EmptyVaultsLoseAtSetup) {
    std::string out = run("SEED 1\nSHUFFLE off\nSTART\nDUMP\n");
    EXPECT_TRUE(contains(out, "DRAW-EMPTY A"));
    EXPECT_TRUE(contains(out, "LOSE A vault"));
    EXPECT_TRUE(contains(out, "LOSE B vault"));
    EXPECT_TRUE(contains(out, "RESULT draw vault"));
    EXPECT_TRUE(contains(out, "turn 1 active A phase dawn decision - over"));
}

TEST(Game, RiteKillsUnitAndErrorsPreserveState) {
    std::string out = run(
        "SEED 1\nSPIRE 10\nOPENING 0\nSHUFFLE off\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-001\nFIELD B TOK-001\nSTART\n"
        "A PLAY 2\nA PLAY 1\nA PLAY 1 #4\nB PASS\nA PASS\nB PASS\nA PASS\nB PASS\n");
    EXPECT_TRUE(contains(out, "ERR 11 no-such-card\n"));
    EXPECT_TRUE(contains(out, "ERR 12 bad-target-count\n"));
    EXPECT_TRUE(contains(out, "8 PLAY A ~1 #2 TST-001 #4\n9 PAY A ember 1\n"));
    EXPECT_TRUE(contains(out, "ERR 14 not-your-turn\n"));
    EXPECT_TRUE(contains(out, "RESOLVE ~1\n13 DAMAGE #2 #4 2\n14 SPENT #2 TST-001\n15 DESTROY #4 TOK-001\n"));
}

TEST(Game, SpireLossEndsTheMatch) {
    std::string out = run(
        "SEED 1\nSPIRE 2\nOPENING 0\nSHUFFLE off\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-001\nSTART\nA PLAY 1 B\nA PASS\nB PASS\nA PASS\n");
    EXPECT_TRUE(contains(out, "SPIRE B -2 0\n"));
    EXPECT_TRUE(contains(out, "LOSE B spire\n"));
    EXPECT_TRUE(contains(out, "RESULT A spire\nERR 13 game-over\n"));
}

TEST(Game, PlatingPreventsPartOfEachHit) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nCAP A 4\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-001 TST-001 TST-001\nFIELD B TST-003\nSTART\n"
        "A PLAY 1 #6\nA PASS\nB PASS\nA PLAY 1 #6\nA PASS\nB PASS\nDUMP\n");
    // Plating 1 turns each 2-damage bolt into 1 damage: two bolts leave 2 wounds on a 3-core unit.
    EXPECT_TRUE(contains(out, "PREVENT #6 1\n"));
    EXPECT_FALSE(contains(out, "TENACITY"));
    EXPECT_TRUE(contains(out, "field B #6 TST-003 0/3 w2 c0 ready"));
}

TEST(Game, NegateRemovesAnEntryAndSendsTheCardToAsh) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nCAP A 3\nCAP B 3\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-001\nHAND B TST-004\nSTART\n"
        "A PLAY 1 B\nA PASS\nB PLAY 1 ~1\nB PASS\nA PASS\nDUMP\n");
    EXPECT_TRUE(contains(out, "NEGATE ~1\n"));
    EXPECT_FALSE(contains(out, "DAMAGE"));
}

TEST(Game, AuraAppliesToOtherUnitsAndAppearsInDump) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nDECK A TOK-001\nDECK B TOK-001\n"
        "FIELD A TST-005 TOK-001\nSTART\nDUMP\n");
    EXPECT_TRUE(contains(out, "field A #2 TST-005 1/1 w0 c0 ready - kw -"));
    EXPECT_TRUE(contains(out, "field A #3 TOK-001 2/2 w0 c0 ready - kw -"));
    EXPECT_TRUE(contains(out, "effect 1 ts2 A aura modify 1 1 on #3\n"));
}

TEST(Game, SummonInterleavesCreateAndArrive) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nCAP A 1\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-006\nSTART\nA PLAY 1\nA PASS\nB PASS\nA PASS\nB PASS\n");
    EXPECT_TRUE(contains(out, "ARRIVE #2 TST-006\n"));
    EXPECT_TRUE(contains(out, "CREATE #4 TOK-001 field\n"));
}

TEST(Game, StripPreventsAuraContribution) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nCAP A 3\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-007\nFIELD A TST-005 TOK-001\nSTART\nA PLAY 1 #3\nA PASS\nB PASS\nDUMP\n");
    EXPECT_TRUE(contains(out, "STRIP #3\n"));
    EXPECT_TRUE(contains(out, "field A #4 TOK-001 1/1"));
    EXPECT_TRUE(contains(out, "aura modify 1 1 on -\n"));
}

TEST(Game, ConcedeEndsTheMatchWithTrace) {
    std::string out = run("SEED 1\nOPENING 0\nSHUFFLE off\nTRACE state\nSTART\nB CONCEDE\nA CONCEDE\nA PASS\n");
    EXPECT_TRUE(contains(out, "ERR 7 not-your-turn\n"));
    EXPECT_TRUE(contains(out, "LOSE A concede\n"));
    EXPECT_TRUE(contains(out, "result B concede\n"));
    EXPECT_TRUE(contains(out, "ERR 9 game-over\n"));
}

TEST(Game, LegalListsPlaysAtMain) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nCAP A 2\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-001 TST-002\nSTART\nLEGAL\n");
    EXPECT_TRUE(contains(out, "LEGAL BEGIN A priority\nPASS\nPLAY 1 TST-001 A\nPLAY 1 TST-001 B\nPLAY 2 TST-002\nLEGAL END\n"));
}

TEST(Game, TurnLimitDrawsTheMatch) {
    // main1 passes, an empty attack, main2 passes, dusk-trigger passes.
    std::string pass = "A PASS\nB PASS\nA ATTACK\nA PASS\nB PASS\nA PASS\nB PASS\n";
    std::string out = run("SEED 1\nOPENING 0\nSHUFFLE off\nTURNLIMIT 1\nDECK A TOK-001*3\nDECK B TOK-001*3\nSTART\n" +
                          pass + "DUMP\n");
    EXPECT_TRUE(contains(out, "RESULT draw turn-limit\n"));
    EXPECT_TRUE(contains(out, "turn 2 active B phase dusk-cleanup decision - over"));
}

TEST(Game, BadSyntaxIsReportedEvenAfterTheMatchEnds) {
    std::string out = run("SEED 1\nSHUFFLE off\nSTART\nDUMP x\n");
    EXPECT_TRUE(contains(out, "ERR 5 bad-syntax\n"));
}

TEST(Game, TenacityReplacesDestructionOnce) {
    std::string out = run(
        "SEED 1\nOPENING 0\nSHUFFLE off\nCAP A 4\nDECK A TOK-001\nDECK B TOK-001\n"
        "HAND A TST-001 TST-001\nFIELD B TST-008\nSTART\n"
        "A PLAY 1 #5\nA PASS\nB PASS\nA PLAY 1 #5\nA PASS\nB PASS\n");
    EXPECT_TRUE(contains(out, "SPENT #2 TST-001\n15 TENACITY #5\n"));
    EXPECT_TRUE(contains(out, "DESTROY #5 TST-008\n"));
}

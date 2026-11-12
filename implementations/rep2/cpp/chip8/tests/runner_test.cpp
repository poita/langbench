#include <gtest/gtest.h>

#include "chip8/runner.hpp"

using namespace chip8;

TEST(Runner, ZeroCyclesRunsNothing) {
    Machine m = run_program(parse_program("6001\n0\n"));
    EXPECT_EQ(m.pc(), 0x200);
    EXPECT_EQ(m.reg(0), 0);
    EXPECT_EQ(m.cycles(), 0u);
}

TEST(Runner, KeyEventTakesEffectBeforeItsCycle) {
    // E0A1 skips if key V0(=0) is up; then F10A waits for a key.
    // cycle0: 6000, cycle1: F10A (waits), event at 2 presses key 3.
    Machine m = run_program(parse_program("6000f10a\n3\n2:0008\n"));
    EXPECT_EQ(m.reg(1), 3);
    EXPECT_EQ(m.pc(), 0x204);
}

TEST(Runner, EventAtNeverApplies) {
    Machine m = run_program(parse_program("f10a\n3\n3:0001\n"));
    EXPECT_EQ(m.pc(), 0x200);
}

TEST(Runner, KeyReleased) {
    // wait for key; keys released again at cycle 3 (no effect after capture)
    Machine m = run_program(parse_program("f10a1202\n4\n1:0004 3:0000\n"));
    EXPECT_EQ(m.reg(1), 2);  // cycle 0 waits, cycle 1 captures key 2 into V1
    EXPECT_EQ(m.reg(0), 0);
}

#include <gtest/gtest.h>

#include <stdexcept>

#include "chip8/program.hpp"
#include "chip8/runner.hpp"

using namespace chip8;

TEST(Program, ParsesTwoLines) {
    Program p = parse_program("60ff\n12\n");
    EXPECT_EQ(p.rom, (std::vector<std::uint8_t>{0x60, 0xff}));
    EXPECT_EQ(p.cycles, 12u);
    EXPECT_TRUE(p.keys.empty());
}

TEST(Program, ParsesThreeLinesNoTrailingNewline) {
    Program p = parse_program("60ff\n12\n3:0001");
    ASSERT_EQ(p.keys.size(), 1u);
    EXPECT_EQ(p.keys[0].cycle, 3u);
}

TEST(Program, EmptyThirdLine) {
    EXPECT_TRUE(parse_program("60ff\n12\n\n").keys.empty());
}

TEST(Program, MaxCycles) { EXPECT_EQ(parse_program("00e0\n4000000000").cycles, 4000000000u); }

TEST(Program, RejectsBadInput) {
    EXPECT_THROW(parse_program(""), std::invalid_argument);
    EXPECT_THROW(parse_program("60ff"), std::invalid_argument);
    EXPECT_THROW(parse_program("60f\n1"), std::invalid_argument);
    EXPECT_THROW(parse_program("\n1"), std::invalid_argument);
    EXPECT_THROW(parse_program("60zz\n1"), std::invalid_argument);
    EXPECT_THROW(parse_program("60ff\nabc"), std::invalid_argument);
    EXPECT_THROW(parse_program(std::string(7170, '0') + "\n1"), std::invalid_argument);
}

TEST(Program, MaxRomAccepted) {
    EXPECT_EQ(parse_program(std::string(7168, '0') + "\n1").rom.size(), 3584u);
}

TEST(Format, Example1) {
    Machine m = run_program(parse_program("60ff7001610180141208\n6\n"));
    std::string out = format_state(m);
    std::string blank = std::string(64, '.') + "\n";
    std::string expected;
    for (int i = 0; i < 32; ++i) expected += blank;
    expected += "PC=0208 I=0000 SP=0 DT=00 ST=00\n";
    expected += "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n";
    EXPECT_EQ(out, expected);
}

TEST(Format, Example3) {
    Machine m = run_program(parse_program(
        "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n"));
    std::string out = format_state(m);
    EXPECT_NE(out.find("PC=021e I=0000 SP=0 DT=07 ST=00\n"), std::string::npos);
    EXPECT_NE(out.find("V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n"), std::string::npos);
}

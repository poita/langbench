#include <gtest/gtest.h>

#include "chip8/job.hpp"

using namespace chip8;

TEST(ParseHex, Basic) {
  EXPECT_EQ(parse_hex("00ff1A"), (std::vector<std::uint8_t>{0x00, 0xff, 0x1a}));
  EXPECT_TRUE(parse_hex("").empty());
}

TEST(ParseHex, Errors) {
  EXPECT_THROW(parse_hex("abc"), ParseError);
  EXPECT_THROW(parse_hex("zz"), ParseError);
}

TEST(ParseKeySchedule, EmptyAndEvents) {
  EXPECT_TRUE(parse_key_schedule("").events().empty());
  KeySchedule s = parse_key_schedule("0:0001 9:0300 14:0000");
  ASSERT_EQ(s.events().size(), 3u);
  EXPECT_EQ(s.events()[1].cycle, 9u);
  EXPECT_EQ(s.events()[1].mask, 0x0300);
}

TEST(ParseKeySchedule, Errors) {
  EXPECT_THROW(parse_key_schedule("5:0001 5:0002"), ParseError);
  EXPECT_THROW(parse_key_schedule("5:0001 4:0002"), ParseError);
  EXPECT_THROW(parse_key_schedule("5"), ParseError);
  EXPECT_THROW(parse_key_schedule("5:001"), ParseError);
  EXPECT_THROW(parse_key_schedule("5:00g1"), ParseError);
  EXPECT_THROW(parse_key_schedule(":0001"), ParseError);
}

TEST(ParseJob, TwoLinesWithAndWithoutNewline) {
  for (const char* text : {"6001\n10\n", "6001\n10", "6001\n10\n\n"}) {
    Job j = parse_job(text);
    EXPECT_EQ(j.rom, (std::vector<std::uint8_t>{0x60, 0x01}));
    EXPECT_EQ(j.cycles, 10u);
    EXPECT_TRUE(j.schedule.events().empty());
  }
}

TEST(ParseJob, ThreeLinesAndLargeCycles) {
  Job j = parse_job("6001\n4000000000\n3:0001\n");
  EXPECT_EQ(j.cycles, 4000000000ull);
  ASSERT_EQ(j.schedule.events().size(), 1u);
}

TEST(ParseJob, Errors) {
  EXPECT_THROW(parse_job(""), ParseError);
  EXPECT_THROW(parse_job("6001\n"), ParseError);
  EXPECT_THROW(parse_job("6001\nabc\n"), ParseError);
  EXPECT_THROW(parse_job("6001\n99999999999999999999999\n"), ParseError);
  EXPECT_THROW(parse_job(std::string(7170, '0') + "\n1\n"), ParseError);
}

TEST(ParseJob, MaxRomAccepted) {
  Job j = parse_job(std::string(7168, 'a') + "\n0\n");
  EXPECT_EQ(j.rom.size(), kMaxRomSize);
}

TEST(RunJob, ExecutesBudget) {
  Machine m = run_job(parse_job("1200\n7\n"));
  EXPECT_EQ(m.cycles(), 7u);
  EXPECT_EQ(m.pc(), 0x200);
}

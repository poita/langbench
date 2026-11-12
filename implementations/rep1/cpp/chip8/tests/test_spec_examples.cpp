// The worked examples of the specification, end to end through the text API.
#include <gtest/gtest.h>

#include <string>

#include "chip8/job.hpp"
#include "chip8/report.hpp"

using namespace chip8;

namespace {

std::string blank_rows(int n) { return [&] { std::string s; for (int i = 0; i < n; ++i) s += std::string(64, '.') + "\n"; return s; }(); }

std::string report_for(const std::string& input) { return format_report(run_job(parse_job(input))); }

}  // namespace

TEST(SpecExamples, ArithmeticAndSelfLoop) {
  EXPECT_EQ(report_for("60ff7001610180141208\n6\n"),
            blank_rows(32) +
                "PC=0208 I=0000 SP=0 DT=00 ST=00\n"
                "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n");
}

TEST(SpecExamples, DrawWrapAround) {
  const std::string expected =
      ".#............................................................#.\n"
      ".#............................................................#.\n"
      "##............................................................##\n" +
      blank_rows(27) +
      "##............................................................##\n"
      ".#............................................................#.\n"
      "PC=020a I=0050 SP=0 DT=00 ST=00\n"
      "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00\n";
  // Rows: 3 top + 27 blank + 2 bottom = 32 display rows.
  EXPECT_EQ(report_for("6a3e6b1e6000f029dab5dab5\n5\n"), expected);
}

TEST(SpecExamples, DrawTwiceErases) {
  EXPECT_EQ(report_for("6a3e6b1e6000f029dab5dab5\n6\n"),
            blank_rows(32) +
                "PC=020c I=0050 SP=0 DT=00 ST=00\n"
                "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01\n");
}

TEST(SpecExamples, RandomTimersKeys) {
  EXPECT_EQ(report_for("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n"),
            blank_rows(32) +
                "PC=021e I=0000 SP=0 DT=07 ST=00\n"
                "V=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n");
}

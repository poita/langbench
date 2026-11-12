#include <algorithm>
#include <gtest/gtest.h>

#include "chip8/job.hpp"
#include "chip8/report.hpp"

using namespace chip8;

TEST(Report, FreshMachine) {
  Machine m;
  EXPECT_EQ(format_status(m), "PC=0200 I=0000 SP=0 DT=00 ST=00");
  EXPECT_EQ(format_registers(m), "V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00");
}

TEST(Report, ShapeIs34Lines) {
  const std::string r = format_report(Machine());
  EXPECT_EQ(std::count(r.begin(), r.end(), '\n'), 34);
  EXPECT_EQ(r.back(), '\n');
}

TEST(Report, LowercaseZeroPaddedHex) {
  Machine m = run_job(parse_job("6aff61016f0eaabc\n4\n"));
  EXPECT_EQ(format_status(m), "PC=0208 I=0abc SP=0 DT=00 ST=00");
  EXPECT_EQ(format_registers(m), "V=00 01 00 00 00 00 00 00 00 00 ff 00 00 00 00 0e");
}

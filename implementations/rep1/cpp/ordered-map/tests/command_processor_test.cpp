#include <gtest/gtest.h>

#include <string>

#include "ordered_map/command_processor.hpp"

using ordered_map::run_script;

namespace {
std::string run(const std::string& in) {
    std::string out;
    EXPECT_TRUE(run_script(in, out));
    return out;
}
}  // namespace

TEST(CommandProcessor, ZeroCommands) {
    EXPECT_EQ(run("0\n"), "");
    EXPECT_EQ(run("0"), "");
}

TEST(CommandProcessor, Example1) {
    EXPECT_EQ(run("12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\n"
                  "insert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8"),
              "0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n");
}

TEST(CommandProcessor, Example2) {
    EXPECT_EQ(run("14\ninsert 10 a\ninsert 20 b\ninsert 30 c\nfloor 25\nceil 25\nfloor 10\n"
                  "ceil 10\nsucc 10\npred 10\nsucc 30\nrank 20\nrank 21\nselect 2\nselect 3\n"),
              "ok\nok\nok\n20\n30\n10\n10\n20\nmissing\nmissing\n1\n2\n30\nmissing\n");
}

TEST(CommandProcessor, ExtremeKeys) {
    EXPECT_EQ(run("9\ninsert -9223372036854775808 lo\ninsert 9223372036854775807 hi\n"
                  "insert 0 zero\nsucc 9223372036854775807\npred -9223372036854775808\n"
                  "floor -9223372036854775807\nceil 1\n"
                  "range -9223372036854775808 9223372036854775807\ndelete 0\n"),
              "ok\nok\nok\nmissing\nmissing\n-9223372036854775808\n9223372036854775807\n"
              "-9223372036854775808 0 9223372036854775807\nok\n");
}

TEST(CommandProcessor, ValuesAreOpaque) {
    EXPECT_EQ(run("4\ninsert 1 missing\ninsert 2 \"'`\\<>|{}#\nget 1\nget 2\n"),
              "ok\nok\nmissing\n\"'`\\<>|{}#\n");
}

TEST(CommandProcessor, ReversedRangeIsEmpty) {
    EXPECT_EQ(run("3\ninsert 1 a\nrange 5 1\nrange 1 1\n"), "ok\nempty\n1\n");
}

TEST(CommandProcessor, MalformedInput) {
    std::string out;
    EXPECT_FALSE(run_script("1\nfrobnicate 1\n", out));
    EXPECT_FALSE(run_script("2\nsize\n", out));
    EXPECT_FALSE(run_script("abc\n", out));
    out.clear();
    EXPECT_FALSE(run_script("1\nget x\n", out));
    EXPECT_TRUE(out.empty());
}

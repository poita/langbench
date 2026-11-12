#include <gtest/gtest.h>

#include <sstream>

#include "spreadsheet/script.h"

using namespace spreadsheet;

namespace {
std::string run(const std::string& input, std::size_t* bad = nullptr) {
  Sheet sheet;
  CommandProcessor p(sheet);
  std::istringstream in(input);
  std::ostringstream out, err;
  std::size_t n = p.run(in, out, err);
  if (bad) *bad = n;
  return out.str();
}
}  // namespace

TEST(Script, WorkedExampleOne) {
  EXPECT_EQ(run("set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\n"
                "set A1 5\nget A3\ndump\n"),
            "42\n#CYCLE!\n#CYCLE!\n37\nA1 5\nA2 32\nA3 37\n");
}

TEST(Script, WorkedExampleTwoDumpOrder) {
  EXPECT_EQ(run("set A1 \"Total\"\nset B1 3\nset B2 4.5\nset B3 \"x\"\nset C1 =SUM(B1:B3)\n"
                "set C2 =A1&\": \"&C1\nset C3 =IF(C1>7, \"big\", \"small\")\ndump\n"),
            "A1 Total\nB1 3\nC1 7.5\nB2 4.5\nC2 Total: 7.5\nB3 x\nC3 big\n");
}

TEST(Script, GetOfEmptyCellPrintsEmptyLine) { EXPECT_EQ(run("get A1\n"), "\n"); }

TEST(Script, EmptySheetDumpsNothing) { EXPECT_EQ(run("dump\n"), ""); }

TEST(Script, LastLineMayLackTerminator) { EXPECT_EQ(run("set A1 1\nget A1"), "1\n"); }

TEST(Script, StringContentKeepsSpaces) {
  EXPECT_EQ(run("set A1 \"  a b  \"\nget A1\n"), "  a b  \n");
}

TEST(Script, ClearEmptiesCell) {
  EXPECT_EQ(run("set A1 5\nclear A1\nget A1\ndump\n"), "\n");
}

TEST(Script, MalformedLinesAreSkippedAndCounted) {
  std::size_t bad = 0;
  EXPECT_EQ(run("frob A1\nset A1\nget a1\nset A1 5\nget A1\n", &bad), "5\n");
  EXPECT_EQ(bad, 3u);
}

#include <gtest/gtest.h>

#include "mdiff/lines.hpp"

using namespace mdiff;

TEST(SplitLines, Empty) { EXPECT_TRUE(split_lines("").empty()); }

TEST(SplitLines, TrailingNewlineMakesNoExtraLine) {
  EXPECT_EQ(split_lines("a\nb\n"), (Lines{"a", "b"}));
}

TEST(SplitLines, MissingFinalNewline) { EXPECT_EQ(split_lines("a\nb"), (Lines{"a", "b"})); }

TEST(SplitLines, EmptyLinesKept) {
  EXPECT_EQ(split_lines("\n\na\n\n"), (Lines{"", "", "a", ""}));
}

TEST(Interner, EqualLinesShareIds) {
  Interner in;
  Lines v = {"x", "y", "x", " x", "x ", ""};
  auto ids = in.intern_all(v);
  EXPECT_EQ(ids[0], ids[2]);
  EXPECT_NE(ids[0], ids[1]);
  EXPECT_NE(ids[0], ids[3]);
  EXPECT_NE(ids[0], ids[4]);
  EXPECT_NE(ids[5], ids[0]);
  EXPECT_EQ(in.size(), 5u);
}

TEST(Interner, SameIdAcrossCalls) {
  Interner in;
  auto a = in.intern_all({"p", "q"});
  auto b = in.intern_all({"q", "p"});
  EXPECT_EQ(a[0], b[1]);
  EXPECT_EQ(a[1], b[0]);
}

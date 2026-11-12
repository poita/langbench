#include <gtest/gtest.h>

#include "mime/text.hpp"

using namespace mime;

TEST(Text, Collapse) {
  EXPECT_EQ(collapse("  a \t b  "), "a b");
  EXPECT_EQ(collapse(""), "");
  EXPECT_EQ(collapse(" \t "), "");
}

TEST(Text, NormalizeNewlines) {
  EXPECT_EQ(normalize_newlines("a\r\nb\r\r\nc\rd"), "a\nb\r\nc\rd");
}

TEST(Text, SplitLines) {
  EXPECT_EQ(split_lines("a\nb\n").size(), 2u);
  EXPECT_EQ(split_lines("a\nb").size(), 2u);
  EXPECT_TRUE(split_lines("").empty());
  auto lines = split_lines("a\r\n\r\nb");
  ASSERT_EQ(lines.size(), 3u);
  EXPECT_EQ(lines[0], "a");
  EXPECT_EQ(lines[1], "");
  EXPECT_EQ(lines[2], "b");
}

TEST(Text, QuotedString) {
  auto q = scan_quoted("\"a\\\\\" x", 0);
  EXPECT_EQ(q.text, "a\\");
  EXPECT_EQ(q.end, 5u);
  auto u = scan_quoted("\"abc\\", 0);
  EXPECT_EQ(u.text, "abc\\");
  EXPECT_EQ(u.end, 5u);
}

TEST(Text, SkipComment) {
  EXPECT_EQ(skip_comment("(a (b) \\) c) d", 0), 12u);
  EXPECT_EQ(skip_comment("(open", 0), 5u);
}

TEST(Text, Escape) {
  EXPECT_EQ(escape("a\\b\n\r\t\"\x01\x7f"), "a\\\\b\\n\\r\\t\\\"\\x01\\x7f");
  EXPECT_EQ(escape("\xc2\x85"), "\\x85");
  EXPECT_EQ(escape("caf\xc3\xa9"), "caf\xc3\xa9");
  EXPECT_EQ(quote("x"), "\"x\"");
}

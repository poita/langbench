#include <gtest/gtest.h>

#include <sstream>
#include <string>

#include "batch.hpp"
#include "regex/error.hpp"

namespace {
std::string batch(const std::string& input) {
  std::istringstream in(input);
  std::ostringstream out;
  regex::run_batch(in, out);
  return out.str();
}
}  // namespace

TEST(Batch, SpecExample1) {
  EXPECT_EQ(batch("3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"),
            "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n");
}

TEST(Batch, SpecExample3) {
  EXPECT_EQ(batch("3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n"),
            "match 0 3|2,2\nno\nno\nmatch 0 2|0,1\nmatch 0 1|-\n"
            "match 1 2|-|-|-\nmatch 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n");
}

TEST(Batch, ZeroSubjectsProduceNoOutput) {
  EXPECT_EQ(batch("2\na\n0\nb\n1\nb\n"), "match 0 1\n");
  EXPECT_EQ(batch("1\na\n0\n"), "");
}

TEST(Batch, LinesAreTakenVerbatim) {
  // Pattern of two spaces; subjects: empty, spaces only, integer-looking.
  EXPECT_EQ(batch("1\n  \n4\n\n   \n  2 \n1\n"), "no\nmatch 0 2\nmatch 0 2\nno\n");
  // An empty pattern line, and a subject that looks like a count.
  EXPECT_EQ(batch("2\n\n1\n5\n^5$\n1\n5\n"), "match 0 0\nmatch 0 1\n");
}

TEST(Batch, PatternWithLeadingAndTrailingSpace) {
  EXPECT_EQ(batch("1\n a \n2\nx a y\nxay\n"), "match 1 4\nno\n");
}

TEST(Batch, MissingFinalNewlineIsTolerated) {
  EXPECT_EQ(batch("1\na\n1\nba"), "match 1 2\n");
}

TEST(Batch, MalformedInputThrows) {
  EXPECT_THROW(batch(""), regex::BatchError);
  EXPECT_THROW(batch("x\n"), regex::BatchError);
  EXPECT_THROW(batch("2\na\n1\nb\n"), regex::BatchError);
  EXPECT_THROW(batch("1\na\n3\nb\n"), regex::BatchError);
  EXPECT_THROW(batch("1\n(\n0\n"), regex::ParseError);
}

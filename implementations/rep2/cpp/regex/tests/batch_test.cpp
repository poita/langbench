#include <gtest/gtest.h>

#include <sstream>
#include <string>

#include "rx/batch.hpp"

namespace {

std::string batch(const std::string& in) {
  std::ostringstream out;
  rx::run_batch(in, out);
  return out.str();
}

}  // namespace

TEST(Batch, SpecExample1) {
  EXPECT_EQ(batch("3\n(a|ab)(c|bcd)(d*)\n1\nabcd\na*\n2\nbbb\n\n^(a+)+$\n2\naaaa\naaab\n"),
            "match 0 4|0,1|1,4|4,4\nmatch 0 0\nmatch 0 0\nmatch 0 4|0,4\nno\n");
}

TEST(Batch, SpecExample3) {
  EXPECT_EQ(batch("3\n(a*)*b\n2\naab\nccc\nx$|^(y)?z\n3\nxz\nyz\nzzz\n(a){0}b|(c)?(d)\n3\nxb\nxcd\nd\n"),
            "match 0 3|2,2\nno\nno\nmatch 0 2|0,1\nmatch 0 1|-\nmatch 1 2|-|-|-\n"
            "match 1 3|-|1,2|2,3\nmatch 0 1|-|-|0,1\n");
}

TEST(Batch, ZeroSubjectsProducesNoOutput) {
  EXPECT_EQ(batch("2\na\n0\nb\n0\n"), "");
}

TEST(Batch, LinesAreVerbatim) {
  // Pattern of two spaces; subjects: empty, spaces only, an integer-looking line.
  EXPECT_EQ(batch("2\n  \n3\n\n   \n1  2\n^$\n2\n\n 3\n"),
            "no\nmatch 0 2\nmatch 1 3\n"
            "match 0 0\nno\n");
}

TEST(Batch, PatternThatLooksLikeANumber) {
  EXPECT_EQ(batch("1\n12\n2\n312\n7\n"), "match 1 3\nno\n");
}

TEST(Batch, EmptyPatternLine) {
  EXPECT_EQ(batch("1\n\n2\nabc\n\n"), "match 0 0\nmatch 0 0\n");
}

TEST(Batch, MissingFinalNewlineIsTolerated) {
  EXPECT_EQ(batch("1\na\n1\nba"), "match 1 2\n");
}

TEST(Batch, MalformedInputThrows) {
  EXPECT_THROW(batch(""), rx::BatchError);
  EXPECT_THROW(batch("x\n"), rx::BatchError);
  EXPECT_THROW(batch("1\na\n2\nb\n"), rx::BatchError);  // truncated subjects
  EXPECT_THROW(batch("1\n(\n1\nb\n"), rx::BatchError);  // invalid pattern
}

TEST(Batch, FormatResult) {
  rx::Match m;
  m.begin = 2;
  m.end = 7;
  m.groups = {rx::Span{2, 4}, rx::Span{}, rx::Span{7, 7}};
  std::string out;
  rx::format_result(true, m, out);
  rx::format_result(false, m, out);
  EXPECT_EQ(out, "match 2 7|2,4|-|7,7\nno\n");
}

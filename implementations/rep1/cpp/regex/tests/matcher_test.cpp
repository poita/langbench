#include <gtest/gtest.h>

#include <string>

#include "regex/regex.hpp"

using namespace regex;

namespace {

// Formats a search result like the CLI: "no" or "S E|g1|g2...".
std::string run(const char* pattern, const std::string& subject) {
  Regex re(pattern);
  auto m = re.search(subject);
  if (!m) return "no";
  std::string out = std::to_string(m->span.begin) + " " + std::to_string(m->span.end);
  for (const auto& g : m->groups) {
    out += '|';
    out += g ? std::to_string(g->begin) + "," + std::to_string(g->end) : "-";
  }
  return out;
}

}  // namespace

TEST(Matcher, Literals) {
  EXPECT_EQ(run("abc", "xxabcxx"), "2 5");
  EXPECT_EQ(run("abc", "ab"), "no");
  EXPECT_EQ(run("A", "a"), "no");  // case-sensitive
  EXPECT_EQ(run("a b", "a b"), "0 3");
}

TEST(Matcher, EmptyPatternMatchesEverywhere) {
  EXPECT_EQ(run("", ""), "0 0");
  EXPECT_EQ(run("", "abc"), "0 0");
}

TEST(Matcher, DotAndClasses) {
  EXPECT_EQ(run("a.c", "abc"), "0 3");
  EXPECT_EQ(run("a.c", "ac"), "no");
  EXPECT_EQ(run("[a-c]+", "xxbcay"), "2 5");
  EXPECT_EQ(run("[^a-c]", "abcd"), "3 4");
  EXPECT_EQ(run("[-+]", "a+"), "1 2");
  EXPECT_EQ(run("\\d+\\.\\d+", "v 3.14!"), "2 6");
  EXPECT_EQ(run("\\w+", "  ab_9 "), "2 6");
  EXPECT_EQ(run("\\s", "ab c"), "2 3");
  EXPECT_EQ(run("\\D\\W\\S", "1 a- !"), "3 6");
}

TEST(Matcher, Anchors) {
  EXPECT_EQ(run("^a", "ba"), "no");
  EXPECT_EQ(run("a$", "ab"), "no");
  EXPECT_EQ(run("a$", "ba"), "1 2");
  EXPECT_EQ(run("^$", ""), "0 0");
  EXPECT_EQ(run("^$", "a"), "no");
  EXPECT_EQ(run("a^b", "ab"), "no");
  EXPECT_EQ(run("x$|^(y)?z", "xz"), "no");
  EXPECT_EQ(run("^a|b", "cb"), "1 2");
  EXPECT_EQ(run("$", "abc"), "3 3");
}

TEST(Matcher, OrderedChoice) {
  EXPECT_EQ(run("a|ab", "ab"), "0 1");
  EXPECT_EQ(run("ab|a", "ab"), "0 2");
  EXPECT_EQ(run("(a|ab)(c|bcd)(d*)", "abcd"), "0 4|0,1|1,4|4,4");
}

TEST(Matcher, GreedyAndBacktracking) {
  EXPECT_EQ(run("a*", "bbb"), "0 0");
  EXPECT_EQ(run("a*ab", "aaab"), "0 4");
  EXPECT_EQ(run("(a+)(a*)", "aaa"), "0 3|0,3|3,3");
  EXPECT_EQ(run("(a*)(a+)", "aaa"), "0 3|0,2|2,3");
  EXPECT_EQ(run(".*b", "abab"), "0 4");
}

TEST(Matcher, CountedQuantifiers) {
  EXPECT_EQ(run("a{3}", "aaaa"), "0 3");
  EXPECT_EQ(run("a{2,}", "aaaa"), "0 4");
  EXPECT_EQ(run("a{2,3}", "aaaa"), "0 3");
  EXPECT_EQ(run("a{2,3}", "a"), "no");
  EXPECT_EQ(run("a{0}b", "ab"), "1 2");
  EXPECT_EQ(run("(ab){2}", "ababab"), "0 4|2,4");
  EXPECT_EQ(run("[^a-c]\\d{2,3}x?", "zz123xx"), "1 6");
}

TEST(Matcher, Captures) {
  EXPECT_EQ(run("(a|(b))+", "ba"), "0 2|1,2|0,1");
  EXPECT_EQ(run("(a|(b))+", "ab"), "0 2|1,2|1,2");
  EXPECT_EQ(run("(a){0}b|(c)?(d)", "xb"), "1 2|-|-|-");
  EXPECT_EQ(run("(a){0}b|(c)?(d)", "xcd"), "1 3|-|1,2|2,3");
  EXPECT_EQ(run("(a){0}b|(c)?(d)", "d"), "0 1|-|-|0,1");
}

TEST(Matcher, FailedAlternativesLeaveNoCaptures) {
  EXPECT_EQ(run("(a)b|ac", "ac"), "0 2|-");
  EXPECT_EQ(run("((a)|b)*c", "abc"), "0 3|1,2|0,1");
}

TEST(Matcher, EmptyIterations) {
  EXPECT_EQ(run("(a*)*b", "aab"), "0 3|2,2");
  EXPECT_EQ(run("(a*)*b", "ccc"), "no");
  EXPECT_EQ(run("(a*){3}", ""), "0 0|0,0");
  EXPECT_EQ(run("(a*)+", "b"), "0 0|0,0");
  EXPECT_EQ(run("(|a)+", "aa"), "0 0|0,0");
  EXPECT_EQ(run("(a|)+", "aa"), "0 2|2,2");
  EXPECT_EQ(run("()*", "x"), "0 0|0,0");
  EXPECT_EQ(run("(a?){2,3}b", "aab"), "0 3|2,2");
}

TEST(Matcher, StartPositionsAndSkipping) {
  EXPECT_EQ(run("b", "aaab"), "3 4");
  EXPECT_EQ(run("ab+", "aaab"), "2 4");
  EXPECT_EQ(run("a|$", "xyz"), "3 3");
  EXPECT_EQ(run("^abc", "abcabc"), "0 3");
  EXPECT_EQ(run("^abc", "xabc"), "no");
  EXPECT_EQ(run("(^a)+", "aa"), "0 1|0,1");
}

TEST(Matcher, DeepBacktrackingDoesNotOverflowStack) {
  std::string subject(1000000, 'x');
  EXPECT_EQ(run("^.*y", subject), "no");
  EXPECT_EQ(run("(x|y)*z", std::string(200000, 'x') + "z"), "0 200001|199999,200000");
}

TEST(Matcher, PathologicalPatternsFinishOnShortSubjects) {
  EXPECT_EQ(run("(a*)*b", std::string(18, 'a')), "no");
  EXPECT_EQ(run("(x+x+)+y", std::string(18, 'x')), "no");
  EXPECT_EQ(run("(a|aa)+c", std::string(25, 'a')), "no");
}

TEST(Matcher, ReusableMatcherGivesIndependentResults) {
  Regex re("(a)|b");
  Matcher m(re.program());
  Match out;
  ASSERT_TRUE(m.search("a", out));
  ASSERT_TRUE(out.groups[0].has_value());
  ASSERT_TRUE(m.search("b", out));
  EXPECT_FALSE(out.groups[0].has_value());
  EXPECT_FALSE(m.search("c", out));
  ASSERT_TRUE(m.search("xa", out));
  EXPECT_EQ(out.span, (Span{1, 2}));
}

TEST(Matcher, LargeCountedExpansionIsRejectedNotExploded) {
  EXPECT_THROW(Regex("(((a{100}){100}){100}){100}"), Error);
  EXPECT_NO_THROW(Regex("(a{100}){100}"));
}

TEST(Regex, GroupCountAndCopy) {
  Regex re("(a)(b)(c)");
  Regex copy = re;
  EXPECT_EQ(copy.group_count(), 3);
  EXPECT_THROW(Regex("("), ParseError);
}

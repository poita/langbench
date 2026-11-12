#include <gtest/gtest.h>

#include <string>

#include "rx/batch.hpp"
#include "rx/regex.hpp"

namespace {

// Runs the pattern and renders the result in the CLI's output format.
std::string run(const std::string& pattern, const std::string& subject) {
  rx::Regex re(pattern);
  std::string out;
  auto m = re.search(subject);
  rx::format_result(m.has_value(), m ? *m : rx::Match{}, out);
  out.pop_back();
  return out;
}

}  // namespace

TEST(Matcher, Literals) {
  EXPECT_EQ(run("abc", "xxabcxx"), "match 2 5");
  EXPECT_EQ(run("abc", "xxabxx"), "no");
  EXPECT_EQ(run("", "abc"), "match 0 0");
  EXPECT_EQ(run("", ""), "match 0 0");
  EXPECT_EQ(run("a b", "a b"), "match 0 3");
}

TEST(Matcher, DotAndClasses) {
  EXPECT_EQ(run("a.c", "abc"), "match 0 3");
  EXPECT_EQ(run("a.c", "ac"), "no");
  EXPECT_EQ(run("[a-c]+", "xxbcaz"), "match 2 5");
  EXPECT_EQ(run("[^a-c]+", "abxyc"), "match 2 4");
  EXPECT_EQ(run("\\d+", "ab123c"), "match 2 5");
  EXPECT_EQ(run("\\w+", "  ab_1 "), "match 2 6");
  EXPECT_EQ(run("\\W", "ab c"), "match 2 3");
  EXPECT_EQ(run("\\s", "ab c"), "match 2 3");
  EXPECT_EQ(run("\\S+", "  ab "), "match 2 4");
  EXPECT_EQ(run("[\\w.]+@", "me.x@y"), "match 0 5");
  EXPECT_EQ(run("a\\.b", "a.b axb"), "match 0 3");
  EXPECT_EQ(run("\\(\\)", "()"), "match 0 2");
}

TEST(Matcher, Anchors) {
  EXPECT_EQ(run("^a", "ba"), "no");
  EXPECT_EQ(run("^a", "ab"), "match 0 1");
  EXPECT_EQ(run("a$", "aba"), "match 2 3");
  EXPECT_EQ(run("a$", "ab"), "no");
  EXPECT_EQ(run("a^b", "ab"), "no");
  EXPECT_EQ(run("^$", ""), "match 0 0");
  EXPECT_EQ(run("^$", "a"), "no");
  EXPECT_EQ(run("$", "abc"), "match 3 3");
  EXPECT_EQ(run("x$|^(y)?z", "xz"), "no");
  EXPECT_EQ(run("(^a|b)+", "bab"), "match 0 1|0,1");
}

TEST(Matcher, OrderedChoice) {
  EXPECT_EQ(run("a|ab", "ab"), "match 0 1");
  EXPECT_EQ(run("(a|ab)(c|bcd)(d*)", "abcd"), "match 0 4|0,1|1,4|4,4");
  EXPECT_EQ(run("b|a", "ab"), "match 0 1");
  EXPECT_EQ(run("x*|y", "y"), "match 0 0");
}

TEST(Matcher, Greedy) {
  EXPECT_EQ(run("a*", "bbb"), "match 0 0");
  EXPECT_EQ(run("a*", "aaa"), "match 0 3");
  EXPECT_EQ(run("a*ab", "aaab"), "match 0 4");
  EXPECT_EQ(run("[^a-c]\\d{2,3}x?", "zz123xx"), "match 1 6");
  EXPECT_EQ(run("a{2}", "aaaa"), "match 0 2");
  EXPECT_EQ(run("a{2,}", "aaaa"), "match 0 4");
  EXPECT_EQ(run("a{1,3}", "aaaa"), "match 0 3");
  EXPECT_EQ(run("a{0}", "aaaa"), "match 0 0");
  EXPECT_EQ(run("a{0,0}b", "ab"), "match 1 2");
  EXPECT_EQ(run("a?a?aa", "aa"), "match 0 2");
  EXPECT_EQ(run("a+", ""), "no");
}

TEST(Matcher, Captures) {
  EXPECT_EQ(run("(a|(b))+", "ba"), "match 0 2|1,2|0,1");
  EXPECT_EQ(run("(a|(b))+", "ab"), "match 0 2|1,2|1,2");
  EXPECT_EQ(run("(a){0}b|(c)?(d)", "xb"), "match 1 2|-|-|-");
  EXPECT_EQ(run("(a){0}b|(c)?(d)", "xcd"), "match 1 3|-|1,2|2,3");
  EXPECT_EQ(run("(a){0}b|(c)?(d)", "d"), "match 0 1|-|-|0,1");
  EXPECT_EQ(run("()", "a"), "match 0 0|0,0");
  EXPECT_EQ(run("(a)(b)?", "ac"), "match 0 1|0,1|-");
  EXPECT_EQ(run("(a*)(a*)", "aa"), "match 0 2|0,2|2,2");
}

TEST(Matcher, FailedPathCapturesAreDiscarded) {
  // The first alternative sets g1 and then fails; g1 must be unset afterwards.
  EXPECT_EQ(run("((a)b|ac)", "ac"), "match 0 2|0,2|-");
}

TEST(Matcher, EmptyIterations) {
  EXPECT_EQ(run("(a*)*b", "aab"), "match 0 3|2,2");
  EXPECT_EQ(run("(a*)*b", "ccc"), "no");
  EXPECT_EQ(run("(a*){3}", ""), "match 0 0|0,0");
  EXPECT_EQ(run("(a*)+", "aa"), "match 0 2|2,2");
  EXPECT_EQ(run("(a?){2,4}", "a"), "match 0 1|1,1");
  EXPECT_EQ(run("(|a)+", "aaa"), "match 0 0|0,0");
  EXPECT_EQ(run("(a|)*b", "ab"), "match 0 2|1,1");
}

TEST(Matcher, StartSkipping) {
  EXPECT_EQ(run("b+", "aaabbb"), "match 3 6");
  EXPECT_EQ(run("^b", "aab"), "no");
  EXPECT_EQ(run("(^a|^b)c", "xbc"), "no");
  EXPECT_EQ(run("[ab]x", "ccbx"), "match 2 4");
  EXPECT_EQ(run("a|$", "ccc"), "match 3 3");
}

TEST(Matcher, Pathological) {
  EXPECT_EQ(run("^(a+)+$", std::string(18, 'a') + "b"), "no");
  EXPECT_EQ(run("(x+x+)+y", std::string(18, 'x')), "no");
  EXPECT_EQ(run("(a|aa)+c", std::string(22, 'a')), "no");
}

TEST(Matcher, DeepBacktrackingDoesNotUseTheCallStack) {
  std::string s(10000, 'a');
  EXPECT_EQ(run(".*b", s), "no");
  EXPECT_EQ(run("^(.*)$", s), "match 0 10000|0,10000");
  EXPECT_EQ(run("(a|b)*", s), "match 0 10000|9999,10000");
}

TEST(Matcher, MatcherIsReusable) {
  rx::Regex re("(a)|b");
  rx::Matcher m(re.program());
  rx::Match out;
  ASSERT_TRUE(m.search("a", out));
  EXPECT_TRUE(out.group(1).matched());
  ASSERT_TRUE(m.search("b", out));  // captures from the previous subject must not leak
  EXPECT_FALSE(out.group(1).matched());
  EXPECT_FALSE(m.search("c", out));
  ASSERT_TRUE(m.search("xa", out));
  EXPECT_EQ(out.begin, 1u);
  EXPECT_EQ(out.group(1), (rx::Span{1, 2}));
}

TEST(Regex, ReportsGroupCountAndErrors) {
  EXPECT_EQ(rx::Regex("(a)(b(c))").group_count(), 3u);
  EXPECT_THROW(rx::Regex("(a"), rx::ParseError);
  EXPECT_THROW(rx::Regex("((((a{100}){100}){100}){100}){100}"), rx::Error);  // expansion limit
}

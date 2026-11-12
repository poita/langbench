// Pathological inputs that must finish quickly (no quadratic behaviour) and
// without recursion depth problems.
#include <chrono>

#include "test_helpers.h"

namespace {

std::string repeat(const std::string& s, int n) {
  std::string out;
  out.reserve(s.size() * static_cast<std::size_t>(n));
  for (int i = 0; i < n; ++i) out += s;
  return out;
}

// Runs the conversion, checks it takes well under the budget, returns the HTML.
std::string timed(const std::string& md, double budget_seconds = 5.0) {
  const auto start = std::chrono::steady_clock::now();
  std::string html = commonmark::to_html(md);
  const std::chrono::duration<double> took = std::chrono::steady_clock::now() - start;
  EXPECT_LT(took.count(), budget_seconds);
  return html;
}

}  // namespace

TEST(Stress, ManyUnmatchedOpenBrackets) {
  const std::string html = timed(repeat("[", 5000) + repeat("]", 5000));
  EXPECT_EQ(html, "<p>" + repeat("[", 5000) + repeat("]", 5000) + "</p>\n");
}

TEST(Stress, ManyDelimiterRuns) {
  timed(repeat("_a ", 100000));
  timed(repeat("**a", 100000) + repeat("b**", 100000));
  timed(repeat("*a ", 50000) + repeat("b* ", 50000));
}

TEST(Stress, ManyBacktickRuns) {
  std::string md;
  for (int i = 0; i < 50000; ++i) md += std::string(static_cast<std::size_t>(i % 50 + 1), '`') + " ";
  timed(md);
  timed(repeat("` ``", 100000));
}

TEST(Stress, ManyFailingLinkTails) {
  timed(repeat("[a](b \"", 40000));
  timed(repeat("[a](<", 40000));
  timed(repeat("<a:", 100000));
}

TEST(Stress, LongSingleParagraphAndCodeBlock) {
  timed(repeat("word *emph* `code` [l](/u) &amp; text\n", 20000));
  const std::string html = timed("```\n" + repeat("line of code <>\n", 50000) + "```\n");
  EXPECT_EQ(html.compare(0, 11, "<pre><code>"), 0);
}

TEST(Stress, HugeList) {
  const std::string html = timed(repeat("1. [a](/b) `c`\n", 12000));
  EXPECT_EQ(html.compare(0, 5, "<ol>\n"), 0);
}

TEST(Stress, DeepBlockNestingWithManyLines) {
  std::string quote;
  for (int i = 0; i < 300; ++i) quote += "> ";
  timed(repeat(quote + "x\n", 2000));
  std::string nested;
  for (int i = 0; i < 300; ++i) nested += std::string(static_cast<std::size_t>(i) * 2, ' ') + "- a\n";
  timed(repeat(nested, 20));
}

#include <gtest/gtest.h>

#include "fulltext/snippet.hpp"

using namespace fulltext;

namespace {
std::vector<std::uint32_t> v(std::initializer_list<std::uint32_t> l) { return l; }
}  // namespace

TEST(BestWindow, ShortDocumentUsesWholeText) {
  const auto a = v({5});
  const AtomOccurrences occ[] = {{1, a}};
  EXPECT_EQ(best_window_start(30, occ), 0u);
  EXPECT_EQ(best_window_start(0, {}), 0u);
}

TEST(BestWindow, NoOccurrencesGivesZero) {
  EXPECT_EQ(best_window_start(100, {}), 0u);
}

TEST(BestWindow, SmallestStartWinsTies) {
  // Single occurrence at 50 of a 1-term atom: windows 21..50 contain it.
  const auto a = v({50});
  const AtomOccurrences occ[] = {{1, a}};
  EXPECT_EQ(best_window_start(100, occ), 21u);
}

TEST(BestWindow, MoreDistinctAtomsBeatsMoreOccurrences) {
  const auto a = v({0, 1, 2, 3, 4});       // five occurrences of atom A near the start
  const auto b = v({10, 90});              // B at 10 and 90
  const auto c = v({95});                  // C near the end
  const AtomOccurrences occ[] = {{1, a}, {1, b}, {1, c}};
  // Window starting at 66 (covers 66..95) holds B and C (2 distinct, 2 total);
  // window 0 holds A and B (2 distinct, 6 total) and wins on occurrences.
  EXPECT_EQ(best_window_start(100, occ), 0u);
  const AtomOccurrences occ2[] = {{1, b}, {1, c}};
  EXPECT_EQ(best_window_start(100, occ2), 66u);
}

TEST(BestWindow, PhraseMustFitInsideWindow) {
  const auto a = v({28});
  const AtomOccurrences occ[] = {{4, a}};  // covers tokens 28..31
  EXPECT_EQ(best_window_start(100, occ), 2u);  // 2..31 is the first window containing it
  const AtomOccurrences huge[] = {{31, a}};    // longer than W: never counts
  EXPECT_EQ(best_window_start(100, huge), 0u);
}

TEST(BestWindow, MatchesBruteForce) {
  const std::size_t L = 75;
  const auto a = v({3, 20, 21, 60, 70});
  const auto b = v({22, 23, 24, 25, 26, 27, 74});
  const AtomOccurrences occ[] = {{2, a}, {1, b}};
  std::size_t best = 0;
  std::pair<int, int> best_score{-1, -1};
  for (std::size_t s = 0; s + kSnippetWindow <= L; ++s) {
    int distinct = 0, total = 0;
    for (const auto& o : occ) {
      int c = 0;
      for (auto p : o.starts) c += (p >= s && p + o.length <= s + kSnippetWindow);
      distinct += c > 0;
      total += c;
    }
    if (std::make_pair(distinct, total) > best_score) {
      best_score = {distinct, total};
      best = s;
    }
  }
  EXPECT_EQ(best_window_start(L, occ), best);
}

TEST(RenderSnippet, CollapsesWhitespaceAndTrimsToTokens) {
  const std::string text = "  ...Hello,\n\t world\xC2\xA0 \xC2\xA0 again!! ";
  const auto spans = tokenize(text);
  EXPECT_EQ(render_snippet(text, spans, 0), "Hello, world again");
  EXPECT_EQ(render_snippet(text, spans, 1, 1), "world");
}

TEST(RenderSnippet, WindowClippedToDocument) {
  const auto text = std::string("a b c");
  EXPECT_EQ(render_snippet(text, tokenize(text), 0), "a b c");
  EXPECT_EQ(render_snippet("", {}, 0), "");
}

#include <gtest/gtest.h>

#include <cmath>

#include "fulltext/bm25.hpp"
#include "fulltext/searcher.hpp"

using namespace fulltext;

TEST(Bm25, IdfMatchesSpecExample) {
  EXPECT_NEAR(bm25_idf(1, 1), std::log(4.0 / 3.0), 1e-12);
  EXPECT_GT(bm25_idf(10, 10), 0.0);
}

TEST(Bm25, TermScoreAndZeroAvgdl) {
  EXPECT_NEAR(bm25_term_score(1.0, 1.0, 9.0, 9.0), 1.0, 1e-12);  // 2.2 / (1 + 1.2)
  EXPECT_NEAR(bm25_term_score(1.0, 1.0, 0.0, 0.0), 2.2 / (1.0 + 1.2 * 0.25), 1e-12);
}

TEST(Searcher, WorkedExampleFromSpec) {
  const Index idx = Index::build({{"note", "The quick brown fox jumps over the lazy dog.\n"}});
  const Searcher s(idx);
  const double one = std::log(4.0 / 3.0);

  auto r = s.search("fox", 10);
  ASSERT_EQ(r.hits.size(), 1u);
  EXPECT_EQ(r.hits[0].id, "note");
  EXPECT_NEAR(r.hits[0].score, one, 1e-9);
  EXPECT_EQ(r.hits[0].snippet, "The quick brown fox jumps over the lazy dog");

  r = s.search("quick brown", 10);
  ASSERT_EQ(r.hits.size(), 1u);
  EXPECT_NEAR(r.hits[0].score, 2 * one, 1e-9);

  EXPECT_TRUE(s.search("cat", 10).hits.empty());
  EXPECT_NEAR(s.search("\"lazy dog\"", 10).hits.at(0).score, one, 1e-9);
}

TEST(Searcher, TiesBrokenByIdAndTermFrequencyWins) {
  const Index idx = Index::build({{"copy3", "alpha beta gamma"},
                                  {"other", "alpha alpha beta"},
                                  {"copy1", "alpha beta gamma"},
                                  {"copy2", "alpha beta gamma"}});
  const auto r = Searcher(idx).search("alpha", 10);
  ASSERT_EQ(r.hits.size(), 4u);
  EXPECT_EQ(r.hits[0].id, "other");
  EXPECT_EQ(r.hits[1].id, "copy1");
  EXPECT_EQ(r.hits[2].id, "copy2");
  EXPECT_EQ(r.hits[3].id, "copy3");
  EXPECT_NEAR(r.hits[0].score, 0.1449, 5e-5);
  EXPECT_NEAR(r.hits[1].score, 0.1054, 5e-5);
}

TEST(Searcher, KLimitsHitsButNotTotalMatches) {
  const Index idx = Index::build({{"a", "x"}, {"b", "x"}, {"c", "x"}});
  const auto r = Searcher(idx).search("x", 2);
  EXPECT_EQ(r.total_matches, 3u);
  ASSERT_EQ(r.hits.size(), 2u);
  EXPECT_EQ(r.hits[0].id, "a");
}

TEST(Searcher, PurelyNegativeQueriesScoreZero) {
  const Index idx = Index::build({{"a", "cat"}, {"b", "dog"}});
  const auto r = Searcher(idx).search("NOT cat", 10);
  ASSERT_EQ(r.hits.size(), 1u);
  EXPECT_EQ(r.hits[0].id, "b");
  EXPECT_EQ(r.hits[0].score, 0.0);
  EXPECT_EQ(r.hits[0].snippet, "dog");  // window 0
}

TEST(Searcher, EmptyTreeMatchesNothing) {
  const Index idx = Index::build({{"a", "the cat"}});
  EXPECT_TRUE(Searcher(idx).search("the", 10).hits.empty());
  EXPECT_TRUE(Searcher(idx).search("", 10).hits.empty());
}

TEST(Searcher, StopWordsStillTakePartInPhrases) {
  const Index idx = Index::build({{"a", "to be or not to be"}, {"b", "be to"}});
  const auto r = Searcher(idx).search("\"to be or not to be\"", 10);
  ASSERT_EQ(r.hits.size(), 1u);
  EXPECT_EQ(r.hits[0].id, "a");
}

TEST(Searcher, SnippetPicksWindowWithMostAtoms) {
  std::string text;
  for (int i = 0; i < 50; ++i) text += "filler ";
  text += "needle haystack\n";
  for (int i = 0; i < 50; ++i) text += "pad ";
  const Index idx = Index::build({{"d", text}});
  const auto r = Searcher(idx).search("needle haystack", 1);
  ASSERT_EQ(r.hits.size(), 1u);
  const std::string& sn = r.hits[0].snippet;
  EXPECT_NE(sn.find("needle haystack"), std::string::npos);
  EXPECT_EQ(sn.find('\n'), std::string::npos);
  EXPECT_EQ(sn.substr(0, 6), "filler");
  // Smallest start that still holds both atoms: the window ends on "haystack".
  EXPECT_EQ(sn.substr(sn.size() - 8), "haystack");
}

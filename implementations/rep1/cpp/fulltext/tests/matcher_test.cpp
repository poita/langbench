#include <gtest/gtest.h>

#include "fulltext/matcher.hpp"

using namespace fulltext;

namespace {
std::vector<std::uint32_t> starts(const PostingList& pl, std::size_t i) {
  auto s = pl.positions(i);
  return {s.begin(), s.end()};
}
using P = std::vector<std::uint32_t>;
}  // namespace

TEST(Matcher, SingleTerm) {
  const Index idx = Index::build({{"a", "x y x"}, {"b", "y"}});
  const PostingList m = match_atom(idx, {"x"});
  ASSERT_EQ(m.size(), 1u);
  EXPECT_EQ(starts(m, 0), (P{0, 2}));
}

TEST(Matcher, PhraseRequiresAdjacency) {
  const Index idx = Index::build({{"a", "x y"}, {"b", "x z y"}, {"c", "y x"}, {"d", "q x y x y"}});
  const PostingList m = match_atom(idx, {"x", "y"});
  ASSERT_EQ(m.size(), 2u);
  EXPECT_EQ(m.doc(0), 0u);
  EXPECT_EQ(m.doc(1), 3u);
  EXPECT_EQ(starts(m, 1), (P{1, 3}));
}

TEST(Matcher, OverlappingOccurrencesAllCount) {
  const Index idx = Index::build({{"a", "aa aa aa aa"}});
  const PostingList m = match_atom(idx, {"aa", "aa"});
  ASSERT_EQ(m.size(), 1u);
  EXPECT_EQ(m.frequency(0), 3u);
}

TEST(Matcher, UnknownTermMatchesNothing) {
  const Index idx = Index::build({{"a", "x y"}});
  EXPECT_TRUE(match_atom(idx, {"x", "nope"}).empty());
  EXPECT_TRUE(match_atom(idx, {"nope"}).empty());
}

TEST(Matcher, ThreeTermPhraseAcrossDocuments) {
  const Index idx = Index::build({{"a", "p q r"}, {"b", "p q"}, {"c", "p q s p q r"}});
  const PostingList m = match_atom(idx, {"p", "q", "r"});
  ASSERT_EQ(m.size(), 2u);
  EXPECT_EQ(m.doc(1), 2u);
  EXPECT_EQ(starts(m, 1), (P{3}));
}

TEST(Evaluate, BooleanAlgebra) {
  const Index idx = Index::build({{"d0", "cat dog"}, {"d1", "cat"}, {"d2", "dog"}, {"d3", "fish"}});
  const auto run = [&](const char* q) {
    AtomMatches m(idx);
    return evaluate(parse_query(q).root.get(), m, idx.num_docs());
  };
  EXPECT_EQ(run("cat dog"), (DocSet{0}));
  EXPECT_EQ(run("cat OR dog"), (DocSet{0, 1, 2}));
  EXPECT_EQ(run("NOT cat"), (DocSet{2, 3}));
  EXPECT_EQ(run("dog NOT cat"), (DocSet{2}));
  EXPECT_EQ(run("NOT NOT cat"), (DocSet{0, 1}));
  EXPECT_EQ(run("()"), (DocSet{}));  // the empty tree matches nothing
  EXPECT_EQ(run("fish OR (cat AND NOT dog)"), (DocSet{1, 3}));
}

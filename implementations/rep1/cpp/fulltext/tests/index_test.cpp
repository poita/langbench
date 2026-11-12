#include <gtest/gtest.h>

#include "fulltext/index.hpp"

using namespace fulltext;

namespace {
std::vector<std::uint32_t> pos(const PostingList& pl, std::size_t i) {
  auto s = pl.positions(i);
  return {s.begin(), s.end()};
}
using P = std::vector<std::uint32_t>;
}  // namespace

TEST(Index, EmptyCorpus) {
  const Index idx = Index::build({});
  EXPECT_EQ(idx.num_docs(), 0u);
  EXPECT_EQ(idx.total_tokens(), 0u);
  EXPECT_EQ(idx.num_terms(), 0u);
  EXPECT_EQ(idx.avgdl(), 0.0);
}

TEST(Index, DocumentsAreOrderedById) {
  const Index idx = Index::build({{"b", "x"}, {"a", "y"}, {"B", "z"}});
  EXPECT_EQ(idx.document(0).id, "B");
  EXPECT_EQ(idx.document(1).id, "a");
  EXPECT_EQ(idx.document(2).id, "b");
}

TEST(Index, PostingsAndStatistics) {
  const Index idx = Index::build({{"d1", "The cat. The dog!"}, {"d2", "cats"}, {"d3", ""}});
  EXPECT_EQ(idx.num_docs(), 3u);
  EXPECT_EQ(idx.total_tokens(), 5u);
  EXPECT_EQ(idx.length(0), 4u);
  EXPECT_EQ(idx.length(2), 0u);
  EXPECT_EQ(idx.num_terms(), 3u);  // the, cat, dog
  EXPECT_DOUBLE_EQ(idx.avgdl(), 5.0 / 3.0);

  const PostingList* the = idx.find("the");
  ASSERT_NE(the, nullptr);
  ASSERT_EQ(the->size(), 1u);
  EXPECT_EQ(pos(*the, 0), (P{0, 2}));

  const PostingList* cat = idx.find("cat");  // "cat" and "cats" share a term
  ASSERT_NE(cat, nullptr);
  ASSERT_EQ(cat->size(), 2u);
  EXPECT_EQ(cat->doc(0), 0u);
  EXPECT_EQ(cat->doc(1), 1u);
  EXPECT_EQ(pos(*cat, 0), (P{1}));
  EXPECT_EQ(pos(*cat, 1), (P{0}));
  EXPECT_EQ(cat->find(1), 1u);
  EXPECT_EQ(cat->find(2), PostingList::npos);

  EXPECT_EQ(idx.find("zebra"), nullptr);
}

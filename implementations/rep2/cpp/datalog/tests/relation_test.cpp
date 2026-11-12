#include <gtest/gtest.h>

#include <set>

#include "datalog/relation.h"

using namespace datalog;

TEST(Relation, InsertIsSetSemantics) {
  Relation r(2);
  Value a[] = {1, 2}, b[] = {2, 1};
  EXPECT_TRUE(r.insert(a));
  EXPECT_FALSE(r.insert(a));
  EXPECT_TRUE(r.insert(b));
  EXPECT_EQ(r.size(), 2u);
  EXPECT_TRUE(r.contains(a));
  Value c[] = {3, 3};
  EXPECT_FALSE(r.contains(c));
  EXPECT_EQ(r.find(b), 1u);
}

TEST(Relation, GrowsPastInitialCapacity) {
  Relation r(2);
  for (Value i = 0; i < 10000; ++i) {
    Value t[] = {i, i * 7};
    ASSERT_TRUE(r.insert(t));
  }
  for (Value i = 0; i < 10000; ++i) {
    Value t[] = {i, i * 7};
    ASSERT_EQ(r.find(t), i);
  }
  EXPECT_EQ(r.size(), 10000u);
}

TEST(Index, ChainsAreAscendingAndComplete) {
  Relation r(2);
  for (Value i = 0; i < 1000; ++i) {
    Value t[] = {i % 10, i};
    r.insert(t);
  }
  Index& idx = r.index(1);  // column 0
  for (Value k = 0; k < 10; ++k) {
    std::uint32_t prev = kNone;
    int n = 0;
    for (std::uint32_t id = idx.first(&k); id != kNone; id = idx.next(id)) {
      EXPECT_EQ(r.tuple(id)[0], k);
      if (prev != kNone) EXPECT_LT(prev, id);
      prev = id;
      ++n;
    }
    EXPECT_EQ(n, 100);
  }
  Value missing = 77;
  EXPECT_EQ(idx.first(&missing), kNone);
}

TEST(Index, SyncPicksUpNewTuplesIncrementally) {
  Relation r(2);
  Value t1[] = {1, 1};
  r.insert(t1);
  Index& idx = r.index(2);  // column 1
  Value t2[] = {5, 1};
  r.insert(t2);
  Value k = 1;
  EXPECT_EQ(idx.first(&k), 0u);
  EXPECT_EQ(idx.next(0), kNone);  // not synced yet
  r.sync_indexes();
  EXPECT_EQ(idx.next(0), 1u);
}

TEST(Index, MultiColumnKey) {
  Relation r(3);
  Value a[] = {1, 2, 3}, b[] = {1, 9, 3}, c[] = {1, 2, 4};
  r.insert(a);
  r.insert(b);
  r.insert(c);
  Index& idx = r.index(0b101);
  Value key[] = {1, 3};
  std::set<std::uint32_t> got;
  for (auto id = idx.first(key); id != kNone; id = idx.next(id)) got.insert(id);
  EXPECT_EQ(got, (std::set<std::uint32_t>{0, 1}));
}

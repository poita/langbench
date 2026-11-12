#include <gtest/gtest.h>

#include "datalog/relation.h"

using namespace datalog;

TEST(Relation, InsertDeduplicates) {
  Relation r(2);
  Value a[] = {1, 2}, b[] = {2, 1};
  EXPECT_TRUE(r.insert(a));
  EXPECT_TRUE(r.insert(b));
  EXPECT_FALSE(r.insert(a));
  EXPECT_EQ(r.size(), 2u);
  EXPECT_TRUE(r.contains(b));
  Value c[] = {1, 1};
  EXPECT_FALSE(r.contains(c));
}

namespace {
// Collects tuple ids on the chain of `key` in `idx` that really match it.
std::vector<TupleId> lookup(const Relation& r, const Index& idx, std::vector<Value> key) {
  std::vector<TupleId> ids;
  for (TupleId id = idx.head(hash_values(key.data(), key.size())); id != kNoTuple;
       id = idx.next(id)) {
    bool ok = true;
    for (size_t k = 0; k < idx.columns().size(); ++k)
      ok = ok && r.tuple(id)[idx.columns()[k]] == key[k];
    if (ok) ids.push_back(id);
  }
  return ids;
}
}  // namespace

TEST(Relation, IndexBuiltOverExistingAndLaterTuples) {
  Relation r(2);
  for (Value i = 0; i < 100; ++i) {
    Value t[] = {i % 10, i};
    r.insert(t);
  }
  const Index& idx = r.index(0b01);  // key: column 0
  for (Value i = 100; i < 5000; ++i) {  // forces several index growths
    Value t[] = {i % 10, i};
    r.insert(t);
  }
  auto ids = lookup(r, idx, {3});
  EXPECT_EQ(ids.size(), 500u);
  // Chains are newest first.
  for (size_t i = 0; i + 1 < ids.size(); ++i) EXPECT_GT(ids[i], ids[i + 1]);
  EXPECT_TRUE(lookup(r, idx, {42}).empty());
}

TEST(Relation, SameIndexReturnedForSameMask) {
  Relation r(3);
  const Index& a = r.index(0b101);
  const Index& b = r.index(0b101);
  const Index& c = r.index(0b010);
  EXPECT_EQ(&a, &b);
  EXPECT_NE(&a, &c);
  EXPECT_EQ(a.columns(), (std::vector<std::uint32_t>{0, 2}));
}

TEST(Relation, ManyTuplesRoundTrip) {
  Relation r(2);
  for (Value i = 0; i < 100000; ++i) {
    Value t[] = {i, -i};
    ASSERT_TRUE(r.insert(t));
  }
  for (Value i = 0; i < 100000; i += 997) {
    Value t[] = {i, -i};
    EXPECT_TRUE(r.contains(t));
  }
  EXPECT_EQ(r.size(), 100000u);
}

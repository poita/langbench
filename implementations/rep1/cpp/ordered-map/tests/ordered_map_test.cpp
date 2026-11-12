#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <limits>
#include <map>
#include <random>
#include <string>

#include "ordered_map/ordered_map.hpp"

using ordered_map::OrderedMap;
constexpr std::int64_t kMin = std::numeric_limits<std::int64_t>::min();
constexpr std::int64_t kMax = std::numeric_limits<std::int64_t>::max();

TEST(OrderedMap, EmptyMap) {
    OrderedMap m;
    EXPECT_TRUE(m.empty());
    EXPECT_EQ(m.size(), 0u);
    EXPECT_FALSE(m.min());
    EXPECT_FALSE(m.max());
    EXPECT_FALSE(m.floor(0));
    EXPECT_FALSE(m.ceil(0));
    EXPECT_FALSE(m.successor(0));
    EXPECT_FALSE(m.predecessor(0));
    EXPECT_EQ(m.rank(5), 0u);
    EXPECT_FALSE(m.select(0));
    EXPECT_TRUE(m.range(kMin, kMax).empty());
    EXPECT_FALSE(m.erase(1));
    EXPECT_EQ(m.find(1), nullptr);
}

TEST(OrderedMap, InsertUpdateFindErase) {
    OrderedMap m;
    EXPECT_TRUE(m.insert(5, "five"));
    EXPECT_FALSE(m.insert(5, "FIVE"));
    ASSERT_NE(m.find(5), nullptr);
    EXPECT_EQ(*m.find(5), "FIVE");
    EXPECT_EQ(m.size(), 1u);
    EXPECT_TRUE(m.erase(5));
    EXPECT_FALSE(m.erase(5));
    EXPECT_TRUE(m.empty());
}

TEST(OrderedMap, NeighbourQueries) {
    OrderedMap m;
    for (int k : {10, 20, 30}) m.insert(k, "v");
    EXPECT_EQ(m.floor(25), 20);
    EXPECT_EQ(m.ceil(25), 30);
    EXPECT_EQ(m.floor(10), 10);
    EXPECT_EQ(m.ceil(10), 10);
    EXPECT_EQ(m.successor(10), 20);
    EXPECT_EQ(m.predecessor(10), std::nullopt);
    EXPECT_EQ(m.successor(30), std::nullopt);
    EXPECT_EQ(m.rank(20), 1u);
    EXPECT_EQ(m.rank(21), 2u);
    EXPECT_EQ(m.select(2), 30);
    EXPECT_EQ(m.select(3), std::nullopt);
}

TEST(OrderedMap, ExtremeKeys) {
    OrderedMap m;
    m.insert(kMin, "lo");
    m.insert(kMax, "hi");
    m.insert(0, "zero");
    EXPECT_EQ(m.successor(kMax), std::nullopt);
    EXPECT_EQ(m.predecessor(kMin), std::nullopt);
    EXPECT_EQ(m.successor(kMin), 0);
    EXPECT_EQ(m.predecessor(kMax), 0);
    EXPECT_EQ(m.floor(kMin + 1), kMin);
    EXPECT_EQ(m.ceil(1), kMax);
    EXPECT_EQ(m.rank(kMax), 2u);
    EXPECT_EQ(m.range(kMin, kMax), (std::vector<std::int64_t>{kMin, 0, kMax}));
    EXPECT_TRUE(m.range(1, 0).empty());
    EXPECT_TRUE(m.validate());
}

TEST(OrderedMap, SortedInsertionStaysBalanced) {
    OrderedMap m;
    const int n = 100000;
    for (int i = 0; i < n; ++i) m.insert(i, "x");
    EXPECT_TRUE(m.validate());
    EXPECT_EQ(m.size(), static_cast<std::size_t>(n));
    for (int i = n - 1; i >= 0; --i) {
        ASSERT_TRUE(m.erase(i));
        if (i % 10007 == 0) ASSERT_TRUE(m.validate());
    }
    EXPECT_TRUE(m.empty());
    EXPECT_TRUE(m.validate());
}

TEST(OrderedMap, ClearAndReuse) {
    OrderedMap m;
    for (int i = 0; i < 100; ++i) m.insert(i, "x");
    m.clear();
    EXPECT_TRUE(m.empty());
    m.insert(7, "seven");
    EXPECT_EQ(*m.find(7), "seven");
    EXPECT_TRUE(m.validate());
}

TEST(OrderedMap, ForEachInRangeVisitsValues) {
    OrderedMap m;
    for (int i = 0; i < 10; ++i) m.insert(i, std::to_string(i * i));
    std::string seen;
    m.for_each_in_range(3, 6, [&](std::int64_t k, const std::string& v) {
        seen += std::to_string(k) + "=" + v + ";";
    });
    EXPECT_EQ(seen, "3=9;4=16;5=25;6=36;");
}

// Randomised differential test against std::map.
TEST(OrderedMap, RandomAgainstStdMap) {
    std::mt19937_64 rng(12345);
    for (int round = 0; round < 4; ++round) {
        const std::int64_t span = round == 0 ? 20 : round == 1 ? 200 : round == 2 ? 5000 : 1000000;
        OrderedMap m;
        std::map<std::int64_t, std::string> ref;
        auto key = [&] { return static_cast<std::int64_t>(rng() % (2 * span)) - span; };
        for (int step = 0; step < 20000; ++step) {
            const std::int64_t k = key();
            const std::string v = std::to_string(rng() % 1000);
            switch (rng() % 8) {
                case 0: case 1: {
                    bool fresh = ref.find(k) == ref.end();
                    ref[k] = v;
                    ASSERT_EQ(m.insert(k, v), fresh);
                    break;
                }
                case 2: case 3:
                    ASSERT_EQ(m.erase(k), ref.erase(k) == 1);
                    break;
                case 4: {
                    auto it = ref.find(k);
                    const std::string* p = m.find(k);
                    ASSERT_EQ(p != nullptr, it != ref.end());
                    if (p) ASSERT_EQ(*p, it->second);
                    break;
                }
                case 5: {
                    auto lb = ref.lower_bound(k), ub = ref.upper_bound(k);
                    ASSERT_EQ(m.ceil(k), lb == ref.end() ? std::nullopt : std::optional(lb->first));
                    ASSERT_EQ(m.successor(k), ub == ref.end() ? std::nullopt : std::optional(ub->first));
                    ASSERT_EQ(m.floor(k), ub == ref.begin() ? std::nullopt : std::optional(std::prev(ub)->first));
                    ASSERT_EQ(m.predecessor(k), lb == ref.begin() ? std::nullopt : std::optional(std::prev(lb)->first));
                    break;
                }
                case 6: {
                    ASSERT_EQ(m.rank(k), static_cast<std::size_t>(std::distance(ref.begin(), ref.lower_bound(k))));
                    if (!ref.empty()) {
                        std::size_t idx = rng() % (ref.size() + 1);
                        auto expect = idx < ref.size() ? std::optional(std::next(ref.begin(), idx)->first) : std::nullopt;
                        ASSERT_EQ(m.select(idx), expect);
                    }
                    break;
                }
                default: {
                    std::int64_t hi = key();
                    std::vector<std::int64_t> expect;
                    for (auto it = ref.lower_bound(k); it != ref.end() && it->first <= hi; ++it)
                        expect.push_back(it->first);
                    ASSERT_EQ(m.range(k, hi), expect);
                }
            }
            ASSERT_EQ(m.size(), ref.size());
            if (step % 500 == 0) ASSERT_TRUE(m.validate());
        }
        EXPECT_TRUE(m.validate());
    }
}

#include <gtest/gtest.h>

#include "textbuffer/cursor.hpp"

using namespace textbuffer;

namespace {

Cursor point(std::uint32_t l, std::uint32_t c, bool primary = false, std::uint32_t goal = 0) {
    Cursor x;
    x.head = {l, c};
    x.primary = primary;
    x.goal = goal;
    return x;
}

Cursor sel(Position anchor, Position head, bool primary = false) {
    Cursor x;
    x.head = head;
    x.anchor = anchor;
    x.primary = primary;
    return x;
}

}  // namespace

TEST(Cursor, RangeEnds) {
    auto fwd = sel({0, 1}, {0, 5});
    EXPECT_EQ(fwd.start(), (Position{0, 1}));
    EXPECT_EQ(fwd.end(), (Position{0, 5}));
    auto back = sel({1, 0}, {0, 2});
    EXPECT_EQ(back.start(), (Position{0, 2}));
    EXPECT_EQ(back.end(), (Position{1, 0}));
    auto p = point(2, 2);
    EXPECT_FALSE(p.hasSelection());
    EXPECT_EQ(p.start(), p.end());
}

TEST(Normalize, SortsByStart) {
    std::vector<Cursor> v{point(2, 0), point(0, 3, true), point(1, 1)};
    normalize(v);
    ASSERT_EQ(v.size(), 3u);
    EXPECT_EQ(v[0].head, (Position{0, 3}));
    EXPECT_EQ(v[1].head, (Position{1, 1}));
    EXPECT_EQ(v[2].head, (Position{2, 0}));
}

TEST(Normalize, PointsOnSamePositionMergeKeepingFirstGoalAndPrimary) {
    std::vector<Cursor> v{point(0, 2, false, 7), point(0, 2, true, 9)};
    normalize(v);
    ASSERT_EQ(v.size(), 1u);
    EXPECT_TRUE(v[0].primary);
    EXPECT_EQ(v[0].goal, 7u);
}

TEST(Normalize, PointInsideSelectionMerges) {
    std::vector<Cursor> v{sel({0, 1}, {0, 6}), point(0, 6), point(0, 3, true)};
    normalize(v);
    ASSERT_EQ(v.size(), 1u);
    EXPECT_EQ(v[0].start(), (Position{0, 1}));
    EXPECT_EQ(v[0].end(), (Position{0, 6}));
    EXPECT_TRUE(v[0].primary);
}

TEST(Normalize, TouchingSelectionsDoNotMerge) {
    std::vector<Cursor> v{sel({0, 0}, {0, 3}), sel({0, 3}, {0, 5})};
    normalize(v);
    EXPECT_EQ(v.size(), 2u);
}

TEST(Normalize, OverlappingSelectionsMergeAndKeepFirstDirection) {
    std::vector<Cursor> v{sel({0, 4}, {0, 0}), sel({0, 2}, {0, 7})};  // backward, forward
    normalize(v);
    ASSERT_EQ(v.size(), 1u);
    EXPECT_EQ(v[0].head, (Position{0, 0}));
    EXPECT_EQ(v[0].anchor, (Position{0, 7}));
}

TEST(Normalize, EqualStartLongerRangeFirst) {
    std::vector<Cursor> v{point(0, 1), sel({0, 1}, {0, 4})};
    normalize(v);
    ASSERT_EQ(v.size(), 1u);
    EXPECT_EQ(v[0].start(), (Position{0, 1}));
    EXPECT_EQ(v[0].end(), (Position{0, 4}));
    EXPECT_EQ(v[0].head, (Position{0, 4}));  // forward: the longer cursor came first
}

TEST(Normalize, StableForEqualRanges) {
    std::vector<Cursor> v{point(0, 2, false, 3), point(0, 2, false, 5)};
    normalize(v);
    ASSERT_EQ(v.size(), 1u);
    EXPECT_EQ(v[0].goal, 3u);
}

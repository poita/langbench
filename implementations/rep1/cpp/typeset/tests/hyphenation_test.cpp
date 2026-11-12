#include <gtest/gtest.h>

#include "typeset/hlist.hpp"
#include "typeset/hyphenation.hpp"

using namespace typeset;

#ifndef TYPESET_TEST_DATA_DIR
#define TYPESET_TEST_DATA_DIR "data"
#endif

TEST(Hyphenation, PatternValuesFollowPositions) {
    PatternSet ps;
    ps.left = 1;
    ps.right = 1;
    ps.addPattern("a1b");
    EXPECT_EQ(ps.breaks("ab"), std::vector<int>{1});
    EXPECT_TRUE(ps.breaks("ba").empty());
}

TEST(Hyphenation, BoundaryMarkersAndMinima) {
    PatternSet ps;
    ps.left = 2;
    ps.right = 2;
    ps.addPattern(".a3b");  // only at the word start
    ps.addPattern("c3d");
    EXPECT_TRUE(ps.breaks("abxx").empty());  // q=1 is below `left`
    EXPECT_EQ(ps.breaks("xxcdxx"), std::vector<int>{3});
    EXPECT_TRUE(ps.breaks("cdxx").empty());
}

TEST(Hyphenation, ExceptionOverridesPatterns) {
    PatternSet ps;
    ps.left = 2;
    ps.right = 3;
    ps.addException("al-go-rithm");
    EXPECT_EQ(ps.breaks("algorithm"), (std::vector<int>{2, 4}));
}

TEST(Hyphenation, ShippedEnglishSetMatchesWorkedTraces) {
    PatternSet en = PatternSet::load(TYPESET_TEST_DATA_DIR, "english");
    EXPECT_EQ(en.breaks("winter"), std::vector<int>{3});
    EXPECT_EQ(en.breaks("typesetting"), (std::vector<int>{7, 8}));
    EXPECT_EQ(en.breaks("national"), (std::vector<int>{2, 4}));
    EXPECT_EQ(en.breaks("introduction"), (std::vector<int>{2, 8}));
    EXPECT_EQ(en.breaks("algorithm"), (std::vector<int>{2, 4}));
}

TEST(Hyphenation, FragmentPointsHandleCoreHyphensAndDiscretionaries) {
    PatternSet ps = PatternSet::parse("chp 1\nleft 2\nright 2\npattern a1b\n");
    // core hyphen: break after '-' with no pre-break text
    auto pts = hyphenationPoints(U"xx-yy", {}, ps);
    ASSERT_EQ(pts.size(), 1u);
    EXPECT_EQ(pts[0].pos, 3u);
    EXPECT_TRUE(pts[0].exHyphen);
    // explicit points suppress Liang
    pts = hyphenationPoints(U"aabxxaabxx", {5}, ps);
    ASSERT_EQ(pts.size(), 1u);
    EXPECT_EQ(pts[0].pos, 5u);
    EXPECT_FALSE(pts[0].exHyphen);
    // without them Liang applies
    pts = hyphenationPoints(U"aabxxaabxx", {}, ps);
    ASSERT_EQ(pts.size(), 2u);
    EXPECT_EQ(pts[0].pos, 2u);
    EXPECT_EQ(pts[1].pos, 7u);
    // a point at the end of the fragment is discarded and does not suppress Liang
    pts = hyphenationPoints(U"aabxxaabxx", {10}, ps);
    EXPECT_EQ(pts.size(), 2u);
    // no letters, no points
    EXPECT_TRUE(hyphenationPoints(U"123", {1}, ps).empty());
}

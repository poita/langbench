#include <gtest/gtest.h>

#include "typeset/font.hpp"

using namespace typeset;

#ifndef TYPESET_TEST_DATA_DIR
#define TYPESET_TEST_DATA_DIR "data"
#endif

TEST(Font, ParsesRecordsAndStripsComments) {
    Face f = Face::parse(
        "cfm 1\n# comment\nface test\nascent 700  # trailing\ndescent 200\nspace 250 125 80\nextra 100\n"
        "default 500\nglyph 65 600\nglyph 66 700\nkern 65 66 -50\n");
    EXPECT_EQ(f.name, "test");
    EXPECT_EQ(f.ascent, 700);
    EXPECT_EQ(f.descent, 200);
    EXPECT_EQ(f.space, 250);
    EXPECT_EQ(f.stretch, 125);
    EXPECT_EQ(f.shrink, 80);
    EXPECT_EQ(f.advance(U'A'), 600);
    EXPECT_EQ(f.advance(U'Z'), 500);  // default
    EXPECT_EQ(f.kern(U'A', U'B'), -50);
    EXPECT_EQ(f.kern(U'B', U'A'), 0);
}

TEST(Font, WidthScalesOnceAfterSummingKerns) {
    Face f = Face::parse("glyph 65 600\nglyph 66 707\nkern 65 66 -3\n");
    // (600 - 3 + 707) = 1304 units at size 1500 -> 1956 exactly (floor of 1956.0)
    EXPECT_EQ(f.width(U"AB", 1500), scaleUnits(1304, 1500));
    // Scaling per glyph would round differently: 900 + 1060 - 4 = 1956 vs single scale
    EXPECT_EQ(f.width(U"", 1000), 0);
}

TEST(Font, FaceResolution) {
    EXPECT_EQ(faceIndex(Family::Serif, false, false), 0);
    EXPECT_STREQ(faceName(faceIndex(Family::Serif, true, true)), "serif-bold-italic");
    EXPECT_STREQ(faceName(faceIndex(Family::Sans, false, true)), "sans-italic");
    EXPECT_STREQ(faceName(faceIndex(Family::Mono, true, true)), "mono");
}

TEST(Font, ShippedSerifMatchesSpecExamples) {
    FontSet fs = FontSet::load(TYPESET_TEST_DATA_DIR);
    const Face& serif = fs.face(0);
    EXPECT_EQ(serif.ascent, 731);
    EXPECT_EQ(serif.descent, 223);
    EXPECT_EQ(serif.width(U"The", 10000), 15630);
    EXPECT_EQ(serif.width(U"Tu", 10000), 10540);
    EXPECT_EQ(serif.width(U"Tu", 11000), 11594);
    EXPECT_EQ(fs.face(8).advance(U'x'), 600);
}

#include <gtest/gtest.h>

#include "typeset/util.hpp"

using namespace typeset;

TEST(Util, FloorDivRoundsTowardsNegativeInfinity) {
    EXPECT_EQ(floorDiv(7, 2), 3);
    EXPECT_EQ(floorDiv(-7, 2), -4);
    EXPECT_EQ(floorDiv(-3307000, 5100), -649);
    EXPECT_EQ(floorDiv(-4, 2), -2);
    EXPECT_EQ(floorDiv(0, 5), 0);
}

TEST(Util, ScaleUsesFloorDivision) {
    EXPECT_EQ(scaleUnits(1563, 10000), 15630);
    EXPECT_EQ(scaleUnits(1054, 11000), 11594);
    EXPECT_EQ(scaleUnits(-60, 10000), -600);
    EXPECT_EQ(scaleUnits(-1, 500), -1);
}

TEST(Util, RomanNumerals) {
    EXPECT_EQ(toRoman(1), "i");
    EXPECT_EQ(toRoman(4), "iv");
    EXPECT_EQ(toRoman(9), "ix");
    EXPECT_EQ(toRoman(14), "xiv");
    EXPECT_EQ(toRoman(40), "xl");
    EXPECT_EQ(toRoman(2026), "mmxxvi");
    EXPECT_EQ(toRoman(4000), "mmmm");
    EXPECT_EQ(toRoman(5001), "mmmmmi");
}

TEST(Util, BijectiveLetters) {
    EXPECT_EQ(toLetters(1), "a");
    EXPECT_EQ(toLetters(26), "z");
    EXPECT_EQ(toLetters(27), "aa");
    EXPECT_EQ(toLetters(28), "ab");
    EXPECT_EQ(toLetters(52), "az");
    EXPECT_EQ(toLetters(53), "ba");
}

TEST(Util, Utf8RoundTrip) {
    std::string s = "a\xC3\xA9\xE2\x80\xA2\xF0\x9F\x98\x80";
    std::u32string u = utf8ToU32(s);
    ASSERT_EQ(u.size(), 4u);
    EXPECT_EQ(u[1], 0xE9u);
    EXPECT_EQ(u[2], 0x2022u);
    EXPECT_EQ(u[3], 0x1F600u);
    EXPECT_EQ(u32ToUtf8(u), s);
    EXPECT_EQ(utf8Length(s), 4u);
}

TEST(Util, Trim) {
    EXPECT_EQ(trim("  a b \t"), "a b");
    EXPECT_EQ(trim("   "), "");
}

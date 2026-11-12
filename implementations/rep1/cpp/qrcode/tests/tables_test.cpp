#include <gtest/gtest.h>

#include "qrcode/tables.hpp"

using namespace qrcode;

TEST(Tables, DataCodewordExamples) {
    EXPECT_EQ(dataCodewords(Ecl::L, 1), 19);
    EXPECT_EQ(dataCodewords(Ecl::M, 1), 16);
    EXPECT_EQ(dataCodewords(Ecl::Q, 1), 13);
    EXPECT_EQ(dataCodewords(Ecl::H, 1), 9);
    EXPECT_EQ(dataCodewords(Ecl::L, 40), 2956);
    EXPECT_EQ(dataCodewords(Ecl::H, 40), 1276);
}

TEST(Tables, RawModules) {
    EXPECT_EQ(rawDataModules(1), 208);
    EXPECT_EQ(rawDataModules(2), 359);
    EXPECT_EQ(rawDataModules(7), 1568);
    EXPECT_EQ(rawDataModules(40), 29648);
    EXPECT_EQ(totalCodewords(40), 3706);
}

TEST(Tables, SymbolSizeAndAlignment) {
    EXPECT_EQ(symbolSize(1), 21);
    EXPECT_EQ(symbolSize(40), 177);
    EXPECT_TRUE(alignmentPositions(1).empty());
    EXPECT_EQ(alignmentPositions(7), (std::vector<int>{6, 22, 38}));
    EXPECT_EQ(alignmentPositions(40).back(), 170);
}

TEST(Tables, AlignmentPositionsAreConsistent) {
    for (int v = 2; v <= 40; ++v) {
        const auto& p = alignmentPositions(v);
        ASSERT_GE(p.size(), 2u) << v;
        EXPECT_EQ(p.front(), 6);
        EXPECT_EQ(p.back(), symbolSize(v) - 7) << v;
    }
}

TEST(Tables, OutOfRangeVersionThrows) {
    EXPECT_THROW(dataCodewords(Ecl::L, 0), std::out_of_range);
    EXPECT_THROW(alignmentPositions(41), std::out_of_range);
}

TEST(Tables, BlockStructureIsConsistent) {
    for (int v = 1; v <= 40; ++v)
        for (Ecl e : {Ecl::L, Ecl::M, Ecl::Q, Ecl::H}) {
            EXPECT_GT(dataCodewords(e, v), 0);
            EXPECT_LT(dataCodewords(e, v), totalCodewords(v));
        }
}

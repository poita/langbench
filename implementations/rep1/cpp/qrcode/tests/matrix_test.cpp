#include <gtest/gtest.h>

#include <cstdlib>

#include "qrcode/matrix.hpp"
#include "qrcode/penalty.hpp"

using namespace qrcode;

TEST(Matrix, FormatBitsKnownValues) {
    // Well-known format strings from ISO/IEC 18004 (after masking with 0x5412).
    EXPECT_EQ(formatBits(Ecl::L, 0), 0b111011111000100u);
    EXPECT_EQ(formatBits(Ecl::M, 0), 0b101010000010010u);
    EXPECT_EQ(formatBits(Ecl::Q, 0), 0b011010101011111u);
    EXPECT_EQ(formatBits(Ecl::H, 0), 0b001011010001001u);
}

TEST(Matrix, VersionBitsKnownValues) {
    EXPECT_EQ(versionBits(7), 0x07C94u);
    EXPECT_EQ(versionBits(8), 0x085BCu);
    EXPECT_EQ(versionBits(40), 0x28C69u);
}

TEST(Matrix, FunctionPatternsVersion1) {
    Matrix m(1);
    m.drawFunctionPatterns();
    EXPECT_TRUE(m.dark(0, 0));
    EXPECT_FALSE(m.dark(1, 1));
    EXPECT_TRUE(m.dark(2, 2));
    EXPECT_FALSE(m.dark(7, 7));  // separator
    EXPECT_TRUE(m.dark(8, 13));  // dark module
    EXPECT_TRUE(m.dark(8, 6));   // timing, even
    EXPECT_FALSE(m.dark(9, 6));  // timing, odd
    EXPECT_TRUE(m.isFunction(8, 0));   // format area
    EXPECT_FALSE(m.isFunction(10, 10));
    int free = 0;
    for (int y = 0; y < 21; ++y)
        for (int x = 0; x < 21; ++x) free += !m.isFunction(x, y);
    EXPECT_EQ(free, rawDataModules(1));
}

TEST(Matrix, DataModuleCountMatchesRawModulesForAllVersions) {
    for (int v = 1; v <= 40; ++v) {
        Matrix m(v);
        m.drawFunctionPatterns();
        int free = 0;
        for (int y = 0; y < m.size(); ++y)
            for (int x = 0; x < m.size(); ++x) free += !m.isFunction(x, y);
        EXPECT_EQ(free, rawDataModules(v)) << "v" << v;
    }
}

TEST(Matrix, AlignmentPatternAtVersion2) {
    Matrix m(2);
    m.drawFunctionPatterns();
    EXPECT_TRUE(m.dark(18, 18));
    EXPECT_FALSE(m.dark(17, 18));
    EXPECT_TRUE(m.dark(16, 16));
    EXPECT_TRUE(m.isFunction(20, 20));
}

TEST(Matrix, MaskConditions) {
    EXPECT_TRUE(maskCondition(0, 1, 1));
    EXPECT_FALSE(maskCondition(1, 0, 1));
    EXPECT_TRUE(maskCondition(2, 3, 5));
    EXPECT_TRUE(maskCondition(4, 3, 2));
    EXPECT_FALSE(maskCondition(4, 0, 2));
    EXPECT_TRUE(maskCondition(5, 0, 7));
}

TEST(Penalty, AllLightSymbol) {
    // 42 lines with a run of 21 (3 + 16 each), 20*20 solid 2x2 blocks, and
    // 0% dark => k = 10.
    Matrix m(1);
    EXPECT_EQ(penaltyScore(m), 42 * 19 + 400 * 3 + 100);
}

TEST(Penalty, CheckerboardScoresZero) {
    Matrix m(1);
    for (int y = 0; y < 21; ++y)
        for (int x = 0; x < 21; ++x) m.setFunction(x, y, (x + y) % 2 == 0);
    EXPECT_EQ(penaltyScore(m), 0);
}

TEST(Penalty, FinderLikePatternsInRows) {
    // Every row is the 21-character string below; every column is therefore a
    // constant run of 21 modules.
    const char* row = "#.###.#....#.###.#...";
    Matrix m(1);
    for (int y = 0; y < 21; ++y)
        for (int x = 0; x < 21; ++x) m.setFunction(x, y, row[x] == '#');

    // N3: "#.###.#...." at x=0 and "....#.###.#" at x=7 in each of the 21 rows.
    const int n3 = 2 * 40 * 21;
    const int n1 = 21 * (3 + 16);  // columns only; no row run reaches 5
    int pairs = 0, dark = 0;
    for (int x = 0; x < 21; ++x) {
        dark += row[x] == '#';
        if (x + 1 < 21) pairs += row[x] == row[x + 1];
    }
    const int n2 = pairs * 20 * 3;
    const int total = 441;
    const int n4 = 10 * (std::abs(20 * dark * 21 - 10 * total) / total);
    EXPECT_EQ(penaltyScore(m), n1 + n2 + n3 + n4);
}
